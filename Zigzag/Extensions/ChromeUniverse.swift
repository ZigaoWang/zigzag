import Foundation

/// Chrome's extension API from `chrome-api.json`: every namespace and its nested functions, events, constants, enums
/// and objects (`storage.local.get`, `privacy.network.webRTCIPHandlingPolicy.get`). Claims must be paths here. Generated
/// by scripts/chrome-api.py from chrome-types; never edit by hand.
nonisolated struct ChromeUniverse: Sendable {
    /// What a path names in Chrome's API.
    enum NodeKind: String, Hashable, Sendable {
        case namespace
        case function
        case event
        case constant
        case enumeration
        case object
        /// One value of an enum, as in `storage.AccessLevel.TRUSTED_CONTEXTS`.
        case enumValue
    }

    private let nodes: [String: NodeKind]

    /// Every path the universe names.
    var paths: Set<String> { Set(nodes.keys) }

    /// Whether Chrome has this member.
    func contains(_ path: String) -> Bool { nodes[path] != nil }

    /// The path's kind, or nil if unknown.
    func kind(of path: String) -> NodeKind? { nodes[path] }

    enum LoadError: LocalizedError {
        case missingResource
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .missingResource:
                return "chrome-api.json is missing from the app"
            case .malformed(let reason):
                return "chrome-api.json is malformed: \(reason)"
            }
        }
    }

    /// The shipped universe. `bundle` is the app's or a test's.
    static func load(bundle: Bundle = .main) throws -> ChromeUniverse {
        guard let url = bundle.url(forResource: "chrome-api", withExtension: "json") else {
            throw LoadError.missingResource
        }
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LoadError.malformed("the top level is not an object")
        }
        var nodes: [String: NodeKind] = [:]
        for (namespace, value) in root {
            guard let spec = value as? [String: Any] else {
                throw LoadError.malformed("\(namespace) is not an object")
            }
            nodes[namespace] = .namespace
            Self.add(spec, at: namespace, to: &nodes)
        }
        return ChromeUniverse(nodes: nodes)
    }

    /// Members of a namespace or object, including nested objects and properties.
    private static func add(_ spec: [String: Any], at path: String, to nodes: inout [String: NodeKind]) {
        for name in spec["functions"] as? [String] ?? [] {
            nodes["\(path).\(name)"] = .function
        }
        for name in spec["events"] as? [String] ?? [] {
            nodes["\(path).\(name)"] = .event
        }
        for name in (spec["constants"] as? [String: Any] ?? [:]).keys {
            nodes["\(path).\(name)"] = .constant
        }
        for (name, values) in spec["enums"] as? [String: Any] ?? [:] {
            nodes["\(path).\(name)"] = .enumeration
            for value in (values as? [String: Any] ?? [:]).keys {
                nodes["\(path).\(name).\(value)"] = .enumValue
            }
        }
        for (name, value) in spec["objects"] as? [String: Any] ?? [:] {
            nodes["\(path).\(name)"] = .object
            if let inner = value as? [String: Any] {
                add(inner, at: "\(path).\(name)", to: &nodes)
            }
        }
        for (name, value) in spec["properties"] as? [String: Any] ?? [:] {
            nodes["\(path).\(name)"] = .object
            if let inner = value as? [String: Any] {
                add(inner, at: "\(path).\(name)", to: &nodes)
            }
        }
    }
}
