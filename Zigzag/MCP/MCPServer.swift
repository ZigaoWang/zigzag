import Foundation
import Network

/// Listens on 127.0.0.1 only, never another interface, and hands each request to the endpoint. All of it runs on
/// its own queue; only the tools themselves go to the main actor.
nonisolated final class MCPServer: @unchecked Sendable {
    enum State: Equatable, Sendable {
        /// `portInUse`: something else holds the port, and an app that connects there hands it the key.
        case starting, ready(port: UInt16), failed(String, portInUse: Bool), stopped
    }
    /// The most connections at once, and the most of those that haven't yet sent the key: one that would go past it
    /// pushes out the oldest keyless one, so connections that never send it can't keep the apps that do out.
    static let maxConnections = 64
    static let maxKeylessConnections = 16

    let endpoint: MCPEndpoint
    private let queue = DispatchQueue(label: "app.zigzag.mcp", qos: .userInitiated)
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var opened = 0
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
        guard let port = NWEndpoint.Port(rawValue: requestedPort) else { set(.failed("Port \(requestedPort) can't be used.", portInUse: false)); return }
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        let listener: NWListener
        do { listener = try NWListener(using: parameters) } catch {
            set(.failed(error.localizedDescription, portInUse: false))
            return
        }
        self.listener = listener
        set(.starting)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            switch state {
            case .ready: self.set(.ready(port: listener.port?.rawValue ?? self.requestedPort))
            case .failed(let error):
                self.set(.failed(Self.describe(error, port: self.requestedPort), portInUse: Self.isPortInUse(error)))
                listener.cancel()
                if self.listener === listener { self.listener = nil }
            case .waiting(let error):
                // The port is taken: say so rather than wait for it.
                self.set(.failed(Self.describe(error, port: self.requestedPort), portInUse: Self.isPortInUse(error)))
                listener.cancel()
                if self.listener === listener { self.listener = nil }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    static func isPortInUse(_ error: NWError) -> Bool {
        if case .posix(let code) = error { return code == .EADDRINUSE }
        return false
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
        // A connection working on a request is never cut for a new one, keyed or not.
        let keyless = connections.values.filter { !$0.keyed && !$0.isBusy }
        if keyless.count >= Self.maxKeylessConnections, let oldest = keyless.min(by: { $0.number < $1.number }) { oldest.cancel() }
        guard connections.count < Self.maxConnections else { connection.cancel(); return }
        opened += 1
        let handler = Connection(connection, number: opened, endpoint: endpoint, queue: queue) { [weak self] done in
            self?.connections[ObjectIdentifier(done)] = nil
        }
        connections[ObjectIdentifier(handler)] = handler
        handler.start()
    }
}

/// One client connection: requests read one after another, each answered before the next is read.
nonisolated private final class Connection: @unchecked Sendable {
    static let idleTimeout: TimeInterval = 120
    /// How long one request may take to arrive whole, from its first byte (or the connection opening): one sent a
    /// byte at a time, to hold a connection open for ever, is cut off however often a byte comes.
    static let requestTimeout: TimeInterval = 15
    /// The answers given before the key is checked, or because it was wrong. Once a request's key is accepted, a
    /// 404 (a session or method not found) is an answer, not a refusal: the connection stays.
    static let refusals: Set<Int> = [401, 403, 404]

    /// Whether a request answered with `status` ends the connection, given whether its key was accepted.
    static func refuses(status: Int, keyAccepted: Bool) -> Bool { !keyAccepted && refusals.contains(status) }

    private let connection: NWConnection
    /// Its place in the order connections opened.
    let number: Int
    /// It has sent a request with the key. Read and written on the server's queue.
    private(set) var keyed = false
    private let endpoint: MCPEndpoint
    private let queue: DispatchQueue
    private var reader = HTTPRequestReader()
    private var busy = false
    /// Working on a request. Read on the server's queue.
    var isBusy: Bool { busy }
    /// The request being answered had the key.
    private var keyAccepted = false
    private var closed = false
    /// The far end has sent all it will.
    private var peerDone = false
    private var idle: DispatchWorkItem?
    /// Running while a request is on its way and not yet whole.
    private var arriving: DispatchWorkItem?
    private let finished: (Connection) -> Void

    init(_ connection: NWConnection, number: Int, endpoint: MCPEndpoint, queue: DispatchQueue, finished: @escaping (Connection) -> Void) {
        self.connection = connection
        self.number = number
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
        // A connection that opens and sends nothing has as long as a request does.
        armArriving()
        receive()
    }

    func cancel() { close() }

    private func close() {
        guard !closed else { return }
        closed = true
        idle?.cancel()
        arriving?.cancel()
        connection.cancel()
        finished(self)
    }

    /// Starts the clock on the request coming in, unless it's running already.
    private func armArriving() {
        guard arriving == nil, !closed else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.busy, !self.closed else { return }
            self.arriving = nil
            self.send(.json(408, RPCError.response(id: nil, code: RPCError.invalidRequest, message: HTTPResponse.reason(408))), keepAlive: false)
        }
        arriving = work
        queue.asyncAfter(deadline: .now() + Self.requestTimeout, execute: work)
    }

    private func requestArrived() {
        arriving?.cancel()
        arriving = nil
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
                // More waiting than any request could be (sent while one is being answered, or framed to never
                // end): the connection is cut.
                guard self.reader.append(data) else {
                    if !self.busy { self.send(.json(413, RPCError.response(id: nil, code: RPCError.invalidRequest, message: HTTPResponse.reason(413))), keepAlive: false) }
                    else { self.close() }
                    return
                }
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
        case .incomplete:
            // Part of the next request is here: it has a while to arrive whole.
            if !reader.buffer.isEmpty { armArriving() }
            return
        case .failure(let status):
            requestArrived()
            send(.json(status, RPCError.response(id: nil, code: RPCError.invalidRequest, message: HTTPResponse.reason(status))), keepAlive: false)
        case .request(let request):
            requestArrived()
            busy = true
            keyAccepted = false
            let endpoint = self.endpoint
            let queue = self.queue
            Task {
                // Keyed as soon as the key is accepted, so a long tool call is never cut for keyless connections.
                // Queued before the answer below, so it's set by the time that's sent.
                let response = await endpoint.handle(request, authorized: {
                    queue.async { self.keyAccepted = true; self.keyed = true }
                })
                queue.async {
                    self.busy = false
                    // Refused (no key, a page's request, the wrong path): answered, then the connection ends.
                    let refused = Self.refuses(status: response.status, keyAccepted: self.keyAccepted)
                    if !refused { self.keyed = true }
                    self.send(response, keepAlive: !request.closes && !refused)
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
