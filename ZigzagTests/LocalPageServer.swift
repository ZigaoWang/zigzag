import Foundation
import Network

/// A web server on this Mac for tests that load real pages: each request's method and path go to `respond`, and what
/// it returns is sent as the whole reply. Nil leaves the request unanswered, a server that never replies.
nonisolated final class LocalPageServer: @unchecked Sendable {
    struct Reply {
        var status = "200 OK"
        var headers: [String: String] = ["Content-Type": "text/html"]
        var body = Data()

        static func html(_ text: String) -> Reply { Reply(body: Data(text.utf8)) }
    }

    let listener: NWListener
    private let queue = DispatchQueue(label: "zigzag.tests.local-page-server")
    /// Connections left waiting, kept so they stay open until the server stops.
    private var held: [NWConnection] = []

    init(_ respond: @escaping @Sendable (_ method: String, _ path: String) -> Reply?) throws {
        listener = try NWListener(using: .tcp, on: .any)
        let queue = queue
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                let words = String(decoding: data ?? Data(), as: UTF8.self).components(separatedBy: " ")
                guard words.count > 1, let reply = respond(words[0], words[1]) else {
                    self?.held.append(connection)
                    return
                }
                var head = "HTTP/1.1 \(reply.status)\r\n"
                for (name, value) in reply.headers { head += "\(name): \(value)\r\n" }
                head += "Content-Length: \(reply.body.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8) + reply.body, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    /// Starts listening; the address is on 127.0.0.1.
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { done in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    done.resume(returning: URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")!)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    done.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        queue.sync {
            held.forEach { $0.cancel() }
            held = []
        }
    }
}
