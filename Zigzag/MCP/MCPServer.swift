import Foundation
import Network

/// Listens on 127.0.0.1 only, never another interface, and hands each request to the endpoint. All of it runs on
/// its own queue; only the tools themselves go to the main actor.
nonisolated final class MCPServer: @unchecked Sendable {
    enum State: Equatable, Sendable {
        case starting, ready(port: UInt16), failed(String), stopped
    }

    let endpoint: MCPEndpoint
    private let queue = DispatchQueue(label: "app.zigzag.mcp", qos: .userInitiated)
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private let requestedPort: UInt16
    /// Told of every change, on the server's queue.
    var onState: (@Sendable (State) -> Void)?
    private(set) var state: State = .stopped

    /// `port` 0 picks any free one (tests).
    init(port: UInt16, endpoint: MCPEndpoint) {
        requestedPort = port
        self.endpoint = endpoint
    }

    func start() {
        queue.async { self.startOnQueue() }
    }

    private func startOnQueue() {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredInterfaceType = .loopback
        guard let port = NWEndpoint.Port(rawValue: requestedPort) else { set(.failed("Port \(requestedPort) can't be used.")); return }
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        let listener: NWListener
        do { listener = try NWListener(using: parameters) } catch {
            set(.failed(error.localizedDescription))
            return
        }
        self.listener = listener
        set(.starting)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            switch state {
            case .ready: self.set(.ready(port: listener.port?.rawValue ?? self.requestedPort))
            case .failed(let error):
                self.set(.failed(Self.describe(error, port: self.requestedPort)))
                listener.cancel()
                if self.listener === listener { self.listener = nil }
            case .waiting(let error):
                // The port is taken: say so rather than wait for it.
                self.set(.failed(Self.describe(error, port: self.requestedPort)))
                listener.cancel()
                if self.listener === listener { self.listener = nil }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    static func describe(_ error: NWError, port: UInt16) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE { return "Port \(port) is in use by another app." }
        return error.localizedDescription
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.connections.values.forEach { $0.cancel() }
            self.connections = [:]
            self.set(.stopped)
        }
    }

    /// Waits until the listener is up (or failed), for tests.
    func waitUntilReady(timeout: TimeInterval = 5) async -> UInt16? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            let current = queue.sync { state }
            if case .ready(let port) = current { return port }
            if case .failed = current { return nil }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

    private func set(_ new: State) {
        state = new
        onState?(new)
    }

    private func accept(_ connection: NWConnection) {
        // Only this Mac: the listener is bound to loopback, and the far end is checked too.
        if case .hostPort(let host, _) = connection.endpoint {
            let loopback: Bool
            switch host {
            case .ipv4(let address): loopback = address.isLoopback
            case .ipv6(let address): loopback = address.isLoopback
            case .name(let name, _): loopback = MCPAccess.loopbackHosts.contains(name.lowercased())
            @unknown default: loopback = false
            }
            guard loopback else { connection.cancel(); return }
        }
        guard connections.count < 64 else { connection.cancel(); return }
        let handler = Connection(connection, endpoint: endpoint, queue: queue) { [weak self] done in
            self?.connections[ObjectIdentifier(done)] = nil
        }
        connections[ObjectIdentifier(handler)] = handler
        handler.start()
    }
}

/// One client connection: requests read one after another, each answered before the next is read.
nonisolated private final class Connection: @unchecked Sendable {
    static let idleTimeout: TimeInterval = 120

    private let connection: NWConnection
    private let endpoint: MCPEndpoint
    private let queue: DispatchQueue
    private var reader = HTTPRequestReader()
    private var busy = false
    private var closed = false
    /// The far end has sent all it will.
    private var peerDone = false
    private var idle: DispatchWorkItem?
    private let finished: (Connection) -> Void

    init(_ connection: NWConnection, endpoint: MCPEndpoint, queue: DispatchQueue, finished: @escaping (Connection) -> Void) {
        self.connection = connection
        self.endpoint = endpoint
        self.queue = queue
        self.finished = finished
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: queue)
        armIdle()
        receive()
    }

    func cancel() { close() }

    private func close() {
        guard !closed else { return }
        closed = true
        idle?.cancel()
        connection.cancel()
        finished(self)
    }

    private func armIdle() {
        idle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.busy else { return }
            self.close()
        }
        idle = work
        queue.asyncAfter(deadline: .now() + Self.idleTimeout, execute: work)
    }

    private func receive() {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.reader.append(data)
                self.armIdle()
                self.process()
            }
            if isComplete || error != nil {
                // The far end is done sending: answer what's there, then close.
                self.peerDone = true
                if !self.busy { self.close() }
                return
            }
            self.receive()
        }
    }

    private func process() {
        guard !busy, !closed else { return }
        switch reader.next() {
        case .incomplete: return
        case .failure(let status):
            send(.json(status, RPCError.response(id: nil, code: RPCError.invalidRequest, message: HTTPResponse.reason(status))), keepAlive: false)
        case .request(let request):
            busy = true
            let endpoint = self.endpoint
            Task {
                let response = await endpoint.handle(request)
                self.queue.async {
                    self.busy = false
                    self.send(response, keepAlive: !request.closes)
                }
            }
        }
    }

    private func send(_ response: HTTPResponse, keepAlive: Bool) {
        guard !closed else { return }
        connection.send(content: response.serialized(keepAlive: keepAlive), completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            if keepAlive, !self.peerDone {
                self.armIdle()
                self.process()
            } else {
                self.close()
            }
        })
    }
}
