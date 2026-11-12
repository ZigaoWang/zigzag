import CryptoKit
import Foundation
import Security

/// What a page's connection proves, read from the trust WebKit checked it with (`WKWebView.serverTrust`): the chain
/// from the site's own certificate up to the root macOS trusts, each with who it was issued to and by, when it's
/// valid, its key and its SHA-256 fingerprint, and whether macOS trusted the whole.
nonisolated struct CertificateDetails: Equatable, Sendable {
    struct Certificate: Equatable, Sendable {
        /// Its subject's common name, or the summary macOS gives.
        var name: String
        var organization: String?
        var issuer: String?
        var validFrom: Date?
        var validUntil: Date?
        /// "RSA" or "EC", with its size in bits.
        var keyType: String?
        var keyBits: Int?
        /// The DER's SHA-256, as colon-separated uppercase pairs.
        var sha256: String
        /// Issued by itself: a root.
        var isSelfSigned: Bool
    }

    /// The site's own first, the root (when the chain has one) last.
    var chain: [Certificate]
    var isTrusted: Bool
    /// Why it isn't trusted, as macOS says it.
    var failure: String?

    enum Role: Equatable, Sendable { case site, intermediate, root }

    /// Where a certificate at `index` stands in a chain of `count`: the site's first (even one issued by itself);
    /// after it, the last is the root once it's issued by itself; any other an intermediate.
    static func role(at index: Int, count: Int, selfSigned: Bool) -> Role {
        if index == 0 { return .site }
        return index == count - 1 && selfSigned ? .root : .intermediate
    }

    func role(at index: Int) -> Role { Self.role(at: index, count: chain.count, selfSigned: chain[index].isSelfSigned) }

    /// From a trust WebKit already checked: its own result, without checking it again on the network. One never
    /// checked is checked here (call off the main thread).
    static func from(_ trust: SecTrust) -> CertificateDetails {
        let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []
        var result = SecTrustResultType.invalid
        SecTrustGetTrustResult(trust, &result)
        var trusted = result == .proceed || result == .unspecified
        var failure: String?
        if result == .invalid {
            var error: CFError?
            trusted = SecTrustEvaluateWithError(trust, &error)
            failure = error.map { CFErrorCopyDescription($0) as String }
        } else if !trusted {
            var error: CFError?
            _ = SecTrustEvaluateWithError(trust, &error)
            failure = error.map { CFErrorCopyDescription($0) as String }
        }
        return CertificateDetails(chain: certificates.map(summary), isTrusted: trusted, failure: trusted ? nil : failure)
    }

    /// One certificate as the panel shows it.
    static func summary(_ certificate: SecCertificate) -> Certificate {
        let subject = names(certificate, oid: kSecOIDX509V1SubjectName)
        let issuer = names(certificate, oid: kSecOIDX509V1IssuerName)
        let fallback = SecCertificateCopySubjectSummary(certificate) as String? ?? ""
        var keyType: String?, keyBits: Int?
        if let key = SecCertificateCopyKey(certificate), let attributes = SecKeyCopyAttributes(key) as? [CFString: Any] {
            let type = attributes[kSecAttrKeyType] as? String
            keyType = type == (kSecAttrKeyTypeRSA as String) ? "RSA" : type == (kSecAttrKeyTypeECSECPrimeRandom as String) ? "EC" : nil
            keyBits = (attributes[kSecAttrKeySizeInBits] as? NSNumber)?.intValue
        }
        let der = SecCertificateCopyData(certificate) as Data
        let digest = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
        let issuerName = issuer["2.5.4.3"] ?? issuer["2.5.4.10"]
        let subjectName = subject["2.5.4.3"] ?? subject["2.5.4.10"] ?? fallback
        return Certificate(name: subjectName, organization: subject["2.5.4.10"], issuer: issuerName,
                           validFrom: SecCertificateCopyNotValidBeforeDate(certificate) as Date?,
                           validUntil: SecCertificateCopyNotValidAfterDate(certificate) as Date?,
                           keyType: keyType, keyBits: keyBits, sha256: digest,
                           isSelfSigned: !subject.isEmpty && subject == issuer)
    }

    /// A name's parts by OID (common name, organization…), the first of each.
    private static func names(_ certificate: SecCertificate, oid: CFString) -> [String: String] {
        guard let values = SecCertificateCopyValues(certificate, [oid] as CFArray, nil) as? [String: Any],
              let entry = values[oid as String] as? [String: Any],
              let parts = entry[kSecPropertyKeyValue as String] as? [[String: Any]] else { return [:] }
        var found: [String: String] = [:]
        for part in parts {
            guard let label = part[kSecPropertyKeyLabel as String] as? String, let value = part[kSecPropertyKeyValue as String] as? String,
                  found[label] == nil else { continue }
            found[label] = value
        }
        return found
    }
}
