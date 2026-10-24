import Foundation

/// A password in memory. It never turns into text by accident: printing, interpolating or dumping it gives
/// "<redacted>", it isn't Codable, and its bytes are wiped when it goes away. The only way to the characters
/// is `withUnsafeString`, used where a password has to be handed to a page or a field.
nonisolated final class SecretString: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private var bytes: [UInt8]

    init(_ string: String) { bytes = Array(string.utf8) }
    init(data: Data) { bytes = Array(data) }

    deinit {
        // Overwrite before the memory is released.
        for i in bytes.indices { bytes[i] = 0 }
    }

    var isEmpty: Bool { bytes.isEmpty }
    var count: Int { String(decoding: bytes, as: UTF8.self).count }

    /// For the Keychain.
    var data: Data { Data(bytes) }

    /// Hands the characters to a closure that must not keep or log them.
    func withUnsafeString<T>(_ body: (String) throws -> T) rethrows -> T {
        try body(String(decoding: bytes, as: UTF8.self))
    }

    /// Compares without leaking where two passwords differ through timing.
    func matches(_ other: SecretString) -> Bool {
        guard bytes.count == other.bytes.count else { return false }
        var difference: UInt8 = 0
        for i in bytes.indices { difference |= bytes[i] ^ other.bytes[i] }
        return difference == 0
    }

    var description: String { "<redacted>" }
    var debugDescription: String { "<redacted>" }
    var customMirror: Mirror { Mirror(self, children: []) }
}
