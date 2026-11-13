import Foundation

/// One HTTP request, as the MCP server reads it off a connection.
nonisolated struct HTTPRequest: Sendable, Equatable {
    var method: String
    /// The path, without its query.
    var path: String
    /// Header names in lower case. A header sent twice keeps its last value.
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// Whether the client wants the connection closed after this response.
    var closes: Bool { header("connection")?.lowercased().contains("close") == true }
}

nonisolated struct HTTPResponse: Sendable, Equatable {
    var status: Int
    var headers: [(String, String)] = []
    var body: Data = Data()

    static func == (a: HTTPResponse, b: HTTPResponse) -> Bool {
        a.status == b.status && a.body == b.body && a.headers.map { "\($0.0): \($0.1)" } == b.headers.map { "\($0.0): \($0.1)" }
    }

    func header(_ name: String) -> String? { headers.last { $0.0.lowercased() == name.lowercased() }?.1 }

    static func json(_ status: Int, _ value: JSON, headers: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "application/json")] + headers, body: value.data)
    }

    static func empty(_ status: Int, headers: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: headers)
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 411: "Length Required"
        case 413: "Content Too Large"
        case 415: "Unsupported Media Type"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }

    /// The bytes sent back. Every response says its length, so the connection can carry the next request.
    func serialized(keepAlive: Bool) -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += keepAlive ? "Connection: keep-alive\r\n" : "Connection: close\r\n"
        head += "\r\n"
        return Data(head.utf8) + body
    }
}

/// Reads requests out of the bytes a connection has delivered so far. Fed more as they come; each complete request
/// is taken off the front, so one connection can carry many.
nonisolated struct HTTPRequestReader: Sendable {
    static let maxHeaderBytes = 32 * 1024
    static let maxBodyBytes = 4 * 1024 * 1024

    enum Outcome: Equatable, Sendable {
        /// More bytes are needed.
        case incomplete
        case request(HTTPRequest)
        /// The bytes can't be a request, or it's too big: answered with this status, then the connection closes.
        case failure(Int)
    }

    /// The most a connection may have sent and not yet been answered for: one whole request at its largest, and some
    /// over for chunk framing. Past it the connection is cut, however the bytes are framed or however slowly they come.
    static let maxBufferedBytes = maxHeaderBytes + maxBodyBytes + 64 * 1024
    /// The most header lines a request may have.
    static let maxHeaderCount = 100

    private(set) var buffer = Data()

    /// Takes more bytes; false once more is waiting than any request could be.
    @discardableResult
    mutating func append(_ data: Data) -> Bool {
        guard data.count <= Self.maxBufferedBytes - buffer.count else { return false }
        buffer.append(data)
        return true
    }

    /// A Content-Length, or a chunk's size: digits only (no sign, no space inside), in base 10 or 16. One too big to
    /// count (7fffffffffffffff and up) is held at Int.max rather than overflowing, so it reads as too large; nil is
    /// anything that isn't a number.
    static func size(_ text: Substring, radix: Int) -> Int? {
        guard !text.isEmpty else { return nil }
        var value = 0
        for character in text {
            guard character.isASCII, let digit = character.hexDigitValue, digit < radix else { return nil }
            let (shifted, overflowA) = value.multipliedReportingOverflow(by: radix)
            let (next, overflowB) = shifted.addingReportingOverflow(digit)
            value = overflowA || overflowB ? Int.max : next
        }
        return value
    }

    mutating func next() -> Outcome {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > Self.maxHeaderBytes ? .failure(431) : .incomplete
        }
        guard headerEnd.lowerBound <= Self.maxHeaderBytes,
              let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else { return .failure(431) }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard start.count == 3, start[2].hasPrefix("HTTP/1."), !start[0].isEmpty,
              start[0].allSatisfy({ $0.isLetter && $0.isUppercase }) else { return .failure(400) }
        guard lines.count <= Self.maxHeaderCount else { return .failure(431) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .failure(400) }
            // No space before the colon (RFC 9112 5.1): a name with one is how requests get read two ways.
            let name = line[..<colon].lowercased()
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "!#$%&'*+-.^_`|~".contains($0)) }) else {
                return .failure(400)
            }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // The headers that say where the body ends are read once: two of them could disagree.
            if ["content-length", "transfer-encoding"].contains(name), headers[name] != nil { return .failure(400) }
            headers[name] = value
        }
        let target = start[1]
        let path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        let bodyStart = headerEnd.upperBound
        var body = Data()
        var consumed: Int
        if let encoding = headers["transfer-encoding"] {
            // Only chunked, alone, and never with a Content-Length beside it.
            guard encoding.lowercased() == "chunked", headers["content-length"] == nil else { return .failure(400) }
            switch Self.dechunk(buffer[bodyStart...]) {
            case .incomplete: return buffer.endIndex - bodyStart > Self.maxBodyBytes + 64 * 1024 ? .failure(413) : .incomplete
            case .invalid: return .failure(400)
            case .tooLarge: return .failure(413)
            case .done(let data, let length):
                body = data
                consumed = bodyStart + length
            }
        } else {
            let length: Int
            if let value = headers["content-length"] {
                guard let parsed = Self.size(Substring(value), radix: 10) else { return .failure(400) }
                length = parsed
            } else {
                length = 0
            }
            // Refused before a byte of it is waited for.
            guard length <= Self.maxBodyBytes else { return .failure(413) }
            guard buffer.endIndex - bodyStart >= length else { return .incomplete }
            body = Data(buffer[bodyStart..<(bodyStart + length)])
            consumed = bodyStart + length
        }
        consumed -= buffer.startIndex
        buffer = Data(buffer.dropFirst(consumed))
        return .request(HTTPRequest(method: start[0], path: path, headers: headers, body: body))
    }

    private enum Chunked { case incomplete, invalid, tooLarge, done(Data, Int) }
    /// The longest a chunk's size line (its size and any extensions) or a trailer line may be.
    static let maxChunkLineBytes = 1024

    private static func dechunk(_ bytes: Data) -> Chunked {
        var index = bytes.startIndex
        var body = Data()
        let crlf = Data("\r\n".utf8)
        while true {
            // A chunk's size line is short: one that runs on without ending isn't one.
            guard let lineEnd = bytes.range(of: crlf, in: index..<bytes.endIndex) else {
                return bytes.endIndex - index > maxChunkLineBytes ? .invalid : .incomplete
            }
            guard lineEnd.lowerBound - index <= maxChunkLineBytes,
                  let line = String(data: bytes[index..<lineEnd.lowerBound], encoding: .ascii),
                  let digits = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first,
                  let size = Self.size(Substring(digits.trimmingCharacters(in: .whitespaces)), radix: 16)
            else { return .invalid }
            index = lineEnd.upperBound
            if size == 0 {
                // Trailers, if any, end with an empty line.
                guard let end = bytes.range(of: Data("\r\n".utf8), in: index..<bytes.endIndex) else { return .incomplete }
                var cursor = end
                while cursor.lowerBound != index {
                    index = cursor.upperBound
                    guard let next = bytes.range(of: crlf, in: index..<bytes.endIndex) else { return .incomplete }
                    cursor = next
                }
                return .done(body, cursor.upperBound - bytes.startIndex)
            }
            // Compared without adding, so a size near Int.max can't overflow into a small one.
            guard size <= maxBodyBytes - body.count else { return .tooLarge }
            guard bytes.endIndex - index >= size + 2 else { return .incomplete }
            body.append(bytes[index..<(index + size)])
            index += size
            guard bytes[index..<(index + 2)] == crlf else { return .invalid }
            index += 2
        }
    }
}
