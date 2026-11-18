import Foundation
import Testing
@testable import Zigzag

/// The AI apps' server reading HTTP: it holds up to sizes and framing meant to break it.
@MainActor
struct MCPHTTPTests {
    @Test func hugeChunkSizesDontOverflow() {
        var reader = HTTPRequestReader()
        reader.append(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n7fffffffffffffff\r\n".utf8))
        #expect(reader.next() == .failure(413))
        var bigger = HTTPRequestReader()
        bigger.append(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\nffffffffffffffffffffffff\r\n".utf8))
        #expect(bigger.next() == .failure(413))
        var signed = HTTPRequestReader()
        signed.append(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n-1\r\n".utf8))
        #expect(signed.next() == .failure(400))
        var endlessLine = HTTPRequestReader()
        endlessLine.append(Data(("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n" + String(repeating: "0", count: HTTPRequestReader.maxChunkLineBytes + 1)).utf8))
        #expect(endlessLine.next() == .failure(400))
        #expect(HTTPRequestReader.size("7fffffffffffffff", radix: 16) == Int.max)
        #expect(HTTPRequestReader.size("80000000000000000", radix: 16) == Int.max)
        #expect(HTTPRequestReader.size("1a", radix: 16) == 26)
        #expect(HTTPRequestReader.size("12", radix: 10) == 12)
        #expect(HTTPRequestReader.size("1a", radix: 10) == nil && HTTPRequestReader.size("", radix: 10) == nil && HTTPRequestReader.size("+1", radix: 10) == nil)
    }

    @Test func bodiesAreFramedOneWayOnly() {
        func outcome(_ head: String) -> HTTPRequestReader.Outcome {
            var reader = HTTPRequestReader()
            reader.append(Data(("POST /mcp HTTP/1.1\r\n" + head + "\r\n").utf8))
            return reader.next()
        }
        #expect(outcome("Content-Length: 2\r\nContent-Length: 5\r\n") == .failure(400))
        #expect(outcome("Content-Length: +2\r\n") == .failure(400))
        #expect(outcome("Content-Length: 2 2\r\n") == .failure(400))
        #expect(outcome("Content-Length: 99999999999999999999999999\r\n") == .failure(413))
        #expect(outcome("Transfer-Encoding: chunked\r\nContent-Length: 2\r\n") == .failure(400))
        #expect(outcome("Transfer-Encoding: gzip, chunked\r\n") == .failure(400))
        #expect(outcome("Content-Length : 2\r\n") == .failure(400))
        #expect(outcome(String(repeating: "X-A: b\r\n", count: HTTPRequestReader.maxHeaderCount + 1)) == .failure(431))
        // Never more held than a request could be.
        var reader = HTTPRequestReader()
        let fits = reader.append(Data(count: HTTPRequestReader.maxBufferedBytes))
        let more = reader.append(Data(count: 1))
        #expect(fits && !more)
    }
}

extension MCPHTTPTests {
    /// A body sent one byte per packet is parsed once, not on every packet.
    @Test func chunkedBodiesAreReadAsTheyCome() {
        var reader = HTTPRequestReader()
        reader.append(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
        let count = 200_000
        let started = Date()
        for _ in 0..<count {
            reader.append(Data("1\r\nx\r\n".utf8))
            #expect(reader.next() == .incomplete)
        }
        reader.append(Data("0\r\nX-Note: fine\r\n\r\nGET".utf8))
        guard case .request(let request) = reader.next() else { Issue.record("no request"); return }
        #expect(request.body == Data(repeating: UInt8(ascii: "x"), count: count))
        #expect(Date().timeIntervalSince(started) < 10)
        // Trailing bytes stay for the next request.
        #expect(reader.buffer == Data("GET".utf8))
    }

    @Test func trailerLinesAreLimited() {
        var long = HTTPRequestReader()
        long.append(Data(("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nX-A: " + String(repeating: "a", count: HTTPRequestReader.maxChunkLineBytes) + "\r\n\r\n").utf8))
        #expect(long.next() == .failure(400))
        var endless = HTTPRequestReader()
        endless.append(Data(("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n" + String(repeating: "a", count: HTTPRequestReader.maxChunkLineBytes + 1)).utf8))
        #expect(endless.next() == .failure(400))
        var many = HTTPRequestReader()
        many.append(Data(("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n" + String(repeating: "X-A: 1\r\n", count: HTTPRequestReader.maxTrailerCount + 1) + "\r\n").utf8))
        #expect(many.next() == .failure(400))
        var some = HTTPRequestReader()
        some.append(Data(("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n" + String(repeating: "X-A: 1\r\n", count: 3) + "\r\n").utf8))
        guard case .request(let request) = some.next() else { Issue.record("no request"); return }
        #expect(request.body == Data("{}".utf8))
    }
}
