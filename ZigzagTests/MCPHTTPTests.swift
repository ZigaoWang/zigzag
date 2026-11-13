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
