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
