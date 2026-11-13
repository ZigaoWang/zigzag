import Compression
import CryptoKit
import Foundation
import Security

/// A Chrome Web Store package (CRX3): a protobuf header of signatures, then a zip. Opening one checks that it
/// really is the extension it claims to be: the header names an ID, a key in the header hashes to that ID, and
/// that key's signature covers the zip byte for byte. Anything else is refused.
nonisolated struct CRXPackage {
    let id: String
    let zip: Data

    enum Failure: Error { case notCRX3, malformed, wrongExtension, unsigned }

    init(_ data: Data, expectedID: String) throws {
        let bytes = [UInt8](data)
        guard bytes.count > 12, bytes[0..<4] == [0x43, 0x72, 0x32, 0x34] /* "Cr24" */ else { throw Failure.notCRX3 }
        guard Self.uint32(bytes, at: 4) == 3 else { throw Failure.notCRX3 }
        let headerLength = Int(Self.uint32(bytes, at: 8))
        guard bytes.count >= 12 + headerLength else { throw Failure.malformed }
        let header = Array(bytes[12..<(12 + headerLength)])
        let archive = data.subdata(in: (12 + headerLength)..<data.count)

        var proofs: [(rsa: Bool, key: [UInt8], signature: [UInt8])] = []
        var signedData: [UInt8]?
        for field in try Self.fields(header) {
            switch field.number {
            case 2, 3:
                var key: [UInt8]?, signature: [UInt8]?
                for sub in try Self.fields(field.value) {
                    if sub.number == 1 { key = sub.value } else if sub.number == 2 { signature = sub.value }
                }
                if let key, let signature { proofs.append((field.number == 2, key, signature)) }
            case 10000:
                signedData = field.value
            default:
                break
            }
        }
        guard let signedData, let crxID = try Self.fields(signedData).first(where: { $0.number == 1 })?.value, crxID.count == 16 else {
            throw Failure.malformed
        }
        let id = Self.extensionID(crxID)
        guard id == expectedID else { throw Failure.wrongExtension }

        // What every signature in the header covers.
        var message = Data("CRX3 SignedData".utf8) + Data([0])
        var length = UInt32(signedData.count).littleEndian
        message.append(Data(bytes: &length, count: 4))
        message.append(contentsOf: signedData)
        message.append(archive)

        // The developer's key is the one whose hash is the ID; its signature is the one that matters.
        let developer = proofs.filter { Array(SHA256.hash(data: $0.key).prefix(16)) == crxID }
        guard developer.contains(where: { Self.verify($0, message: message) }) else { throw Failure.unsigned }
        self.id = id
        self.zip = archive
    }

    /// Chrome's ID alphabet: each hex digit of the key hash becomes a letter from a to p.
    static func extensionID(_ hash: [UInt8]) -> String {
        String(hash.flatMap { [$0 >> 4, $0 & 0x0F] }.map { Character(UnicodeScalar(UInt8(ascii: "a") + $0)) })
    }

    private static func verify(_ proof: (rsa: Bool, key: [UInt8], signature: [UInt8]), message: Data) -> Bool {
        if proof.rsa {
            guard let pkcs1 = rsaPublicKey(fromSPKI: proof.key),
                  let key = SecKeyCreateWithData(Data(pkcs1) as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil) else { return false }
            return SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, Data(proof.signature) as CFData, nil)
        }
        guard let key = try? P256.Signing.PublicKey(derRepresentation: proof.key),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: proof.signature) else { return false }
        return key.isValidSignature(signature, for: message)
    }

    /// Security wants the bare RSA key; the package carries it wrapped in a SubjectPublicKeyInfo.
    private static func rsaPublicKey(fromSPKI der: [UInt8]) -> [UInt8]? {
        var reader = DER(der)
        guard var spki = reader.read(tag: 0x30) else { return nil }
        guard spki.read(tag: 0x30) != nil, let bitString = spki.readValue(tag: 0x03), bitString.first == 0 else { return nil }
        return Array(bitString.dropFirst())
    }

    // MARK: Protobuf, just enough for the header

    private static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    private static func fields(_ bytes: [UInt8]) throws -> [(number: Int, value: [UInt8])] {
        var result: [(Int, [UInt8])] = []
        var index = 0
        func varint() throws -> UInt64 {
            var value: UInt64 = 0, shift: UInt64 = 0
            while true {
                guard index < bytes.count, shift < 64 else { throw Failure.malformed }
                let byte = bytes[index]
                index += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte < 0x80 { return value }
                shift += 7
            }
        }
        while index < bytes.count {
            let key = try varint()
            switch key & 7 {
            case 0: _ = try varint()
            case 2:
                guard let length = Int(exactly: try varint()), length <= bytes.count - index else { throw Failure.malformed }
                result.append((Int(key >> 3), Array(bytes[index..<(index + length)])))
                index += length
            default: throw Failure.malformed
            }
        }
        return result
    }
}

/// Reads DER tag-length-value items in order.
nonisolated private struct DER {
    private var bytes: ArraySlice<UInt8>
    init(_ bytes: [UInt8]) { self.bytes = bytes[...] }
    private init(slice: ArraySlice<UInt8>) { bytes = slice }

    mutating func read(tag: UInt8) -> DER? { readValue(tag: tag).map { DER(slice: $0[...]) } }

    mutating func readValue(tag: UInt8) -> [UInt8]? {
        guard bytes.count >= 2, bytes.first == tag else { return nil }
        var index = bytes.startIndex + 1
        var length = Int(bytes[index])
        index += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count > 0, count <= 4, bytes.endIndex - index >= count else { return nil }
            length = 0
            for _ in 0..<count { length = length << 8 | Int(bytes[index]); index += 1 }
        }
        guard bytes.endIndex - index >= length else { return nil }
        let value = Array(bytes[index..<(index + length)])
        bytes = bytes[(index + length)...]
        return value
    }
}

/// The zip inside a package, unpacked by Zigzag itself rather than by a tool that writes first and is checked after.
/// Every entry is read from the archive's own index and checked before anything is written: a name that is absolute,
/// climbs out with `..` or has a backslash in it; a symbolic link, or any other entry that isn't a plain file or folder;
/// two entries for the same file; encryption, or a way of packing other than none and deflate; sizes that don't add
/// up. Any of these and nothing is unpacked at all. Files are then written only into the new folder, never over one
/// already there, and each one's bytes must match the size and checksum the index gives them.
nonisolated enum PackageZip {
    struct Entry: Equatable {
        /// The path inside the package, its parts checked.
        var path: [String]
        var isDirectory: Bool
        var method: UInt16
        var compressedSize: Int
        var size: Int
        var crc: UInt32
        var localHeader: Int
    }

    enum Failure: Error, Equatable {
        case malformed
        /// Packed in a way Zigzag doesn't read (encrypted, zip64, a method other than stored or deflate).
        case unsupported
        /// A name that would land outside the folder, or isn't a plain one.
        case unsafeName(String)
        /// A link, a device, or anything else that isn't a plain file or folder.
        case notAFile(String)
        case duplicate(String)
        case tooLarge
        /// Bytes that don't match what the index says of them.
        case damaged(String)
    }

    /// Far more than any extension: the largest in the store unpack to a few hundred megabytes.
    static let maxTotalSize = 2 << 30
    static let maxEntries = 65_000

    /// The entries, from the archive's index, each checked.
    static func entries(_ data: Data) throws -> [Entry] {
        let bytes = [UInt8](data)
        // The end-of-index record: 22 bytes and a comment of up to 64 KB, at the very end.
        guard bytes.count >= 22 else { throw Failure.malformed }
        var end = -1
        var at = bytes.count - 22
        let earliest = max(0, bytes.count - 22 - 0xFFFF)
        while at >= earliest {
            if uint32(bytes, at) == 0x0605_4B50, at + 22 + Int(uint16(bytes, at + 20)) == bytes.count { end = at; break }
            at -= 1
        }
        guard end >= 0 else { throw Failure.malformed }
        let count = Int(uint16(bytes, end + 10)), size = Int(uint32(bytes, end + 12)), offset = Int(uint32(bytes, end + 16))
        // One disk only, and no zip64, whose markers are these largest values.
        guard uint16(bytes, end + 4) == 0, uint16(bytes, end + 6) == 0, Int(uint16(bytes, end + 8)) == count else { throw Failure.unsupported }
        guard count != 0xFFFF, size != 0xFFFF_FFFF, offset != 0xFFFF_FFFF else { throw Failure.unsupported }
        guard count <= maxEntries else { throw Failure.tooLarge }
        guard offset <= end, size <= end - offset else { throw Failure.malformed }

        var entries: [Entry] = []
        var seen = Set<String>()
        var total = 0
        var index = offset
        for _ in 0..<count {
            guard index + 46 <= offset + size, uint32(bytes, index) == 0x0201_4B50 else { throw Failure.malformed }
            let madeBy = uint16(bytes, index + 4) >> 8
            let flags = uint16(bytes, index + 8), method = uint16(bytes, index + 10)
            let crc = uint32(bytes, index + 16)
            let compressedSize = Int(uint32(bytes, index + 20)), entrySize = Int(uint32(bytes, index + 24))
            let nameLength = Int(uint16(bytes, index + 28)), extraLength = Int(uint16(bytes, index + 30))
            let commentLength = Int(uint16(bytes, index + 32))
            let external = uint32(bytes, index + 38), localHeader = Int(uint32(bytes, index + 42))
            let next = index + 46 + nameLength + extraLength + commentLength
            guard next <= offset + size else { throw Failure.malformed }
            let raw = Array(bytes[(index + 46)..<(index + 46 + nameLength)])
            let name = String(bytes: raw, encoding: .utf8) ?? String(bytes: raw, encoding: .isoLatin1) ?? ""
            index = next

            // Encrypted, or strongly encrypted.
            guard flags & 0x1 == 0, flags & 0x40 == 0 else { throw Failure.unsupported }
            guard method == 0 || method == 8 else { throw Failure.unsupported }
            guard compressedSize != 0xFFFF_FFFF, entrySize != 0xFFFF_FFFF, localHeader != 0xFFFF_FFFF else { throw Failure.unsupported }
            guard let path = safePath(name) else { throw Failure.unsafeName(name) }
            let isDirectory = name.hasSuffix("/")
            // Made on a Unix system, an entry says what it is: only plain files and folders are taken.
            if madeBy == 3 {
                let type = (external >> 16) & 0o170000
                if type != 0, type != (isDirectory ? 0o040000 : 0o100000) { throw Failure.notAFile(name) }
            }
            if isDirectory, entrySize != 0 { throw Failure.malformed }
            // The Mac's file system ignores case: two names that differ only in it are the same file.
            guard seen.insert(path.joined(separator: "/").lowercased()).inserted else { throw Failure.duplicate(name) }
            guard localHeader < offset, compressedSize <= offset - localHeader else { throw Failure.malformed }
            if method == 0, compressedSize != entrySize { throw Failure.damaged(name) }
            total += entrySize
            guard total <= maxTotalSize else { throw Failure.tooLarge }
            entries.append(Entry(path: path, isDirectory: isDirectory, method: method, compressedSize: compressedSize,
                                 size: entrySize, crc: crc, localHeader: localHeader))
        }
        // No file is also the folder of another entry.
        let files = Set(entries.filter { !$0.isDirectory }.map { $0.path.joined(separator: "/").lowercased() })
        for entry in entries where entry.path.count > 1 {
            for depth in 1..<entry.path.count where files.contains(entry.path.prefix(depth).joined(separator: "/").lowercased()) {
                throw Failure.duplicate(entry.path.joined(separator: "/"))
            }
        }
        return entries
    }

    /// The parts of a name that stays inside the folder, or nil: no absolute name, no `.`, `..` or empty part, no
    /// backslash (a separator elsewhere), no control characters.
    static func safePath(_ name: String) -> [String]? {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        var parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if name.hasSuffix("/") { parts.removeLast() }
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        return parts
    }

    /// Unpacks every entry into `folder`, which must be new or empty. Throws at the first entry that isn't right, with
    /// nothing written if the index itself isn't; the caller removes the folder.
    static func unpack(_ data: Data, into folder: URL) throws {
        let entries = try entries(data)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        guard try fileManager.contentsOfDirectory(atPath: folder.path).isEmpty else { throw Failure.malformed }
        let bytes = [UInt8](data)
        for entry in entries {
            let name = entry.path.joined(separator: "/")
            let url = entry.path.reduce(folder) { $0.appendingPathComponent($1, isDirectory: false) }
            if entry.isDirectory {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
                continue
            }
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let content = try self.content(of: entry, in: bytes)
            guard crc32(content) == entry.crc else { throw Failure.damaged(name) }
            // Never over something already there, so nothing written can be made to land through another entry.
            try Data(content).write(to: url, options: .withoutOverwriting)
        }
    }

    private static func content(of entry: Entry, in bytes: [UInt8]) throws -> [UInt8] {
        let name = entry.path.joined(separator: "/")
        let header = entry.localHeader
        guard header + 30 <= bytes.count, uint32(bytes, header) == 0x0403_4B50 else { throw Failure.malformed }
        let start = header + 30 + Int(uint16(bytes, header + 26)) + Int(uint16(bytes, header + 28))
        guard start <= bytes.count, entry.compressedSize <= bytes.count - start else { throw Failure.malformed }
        let packed = Array(bytes[start..<(start + entry.compressedSize)])
        if entry.method == 0 { return packed }
        guard entry.size > 0 else { return [] }
        guard !packed.isEmpty else { throw Failure.damaged(name) }
        var output = [UInt8](repeating: 0, count: entry.size)
        let written = packed.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { target in
                compression_decode_buffer(target.baseAddress!, entry.size, source.baseAddress!, entry.compressedSize, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == entry.size else { throw Failure.damaged(name) }
        return output
    }

    private static let crcTable: [UInt32] = (0..<256).map { value -> UInt32 in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
        return crc
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    private static func uint16(_ bytes: [UInt8], _ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
    private static func uint32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }
}
