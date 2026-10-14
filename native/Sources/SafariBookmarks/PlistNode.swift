import Foundation

public enum SafariBookmarkError: Error, CustomStringConvertible {
    case malformed(String)
    case rootNotFound(String)
    case precondition(String)
    case invalidOp(String)

    public var code: String {
        switch self {
        case .malformed: return "malformed"
        case .rootNotFound: return "rootNotFound"
        case .precondition: return "precondition"
        case .invalidOp: return "invalidOp"
        }
    }

    public var description: String {
        switch self {
        case .malformed(let m): return "malformed plist: \(m)"
        case .rootNotFound(let m): return "root not found: \(m)"
        case .precondition(let m): return "precondition failed: \(m)"
        case .invalidOp(let m): return "invalid op: \(m)"
        }
    }
}

/// One node of Safari's Bookmarks.plist. Everything except `Children` stays in `dict`
/// untouched (CloudKit `Sync` data, unknown keys, types), so a round trip only changes
/// what an op explicitly changes.
public final class PlistNode {
    public var dict: [String: Any]
    public var children: [PlistNode]?

    public init(dict: [String: Any], children: [PlistNode]?) {
        self.dict = dict
        self.children = children
    }

    public convenience init(plist: Any) throws {
        guard var d = plist as? [String: Any] else {
            throw SafariBookmarkError.malformed("node is not a dictionary")
        }
        var kids: [PlistNode]?
        if let arr = d["Children"] as? [Any] {
            kids = try arr.map { try PlistNode(plist: $0) }
            d.removeValue(forKey: "Children")
        }
        self.init(dict: d, children: kids)
    }

    public func toPlist() -> [String: Any] {
        var d = dict
        if let c = children { d["Children"] = c.map { $0.toPlist() } }
        return d
    }

    public func deepCopy() -> PlistNode {
        PlistNode(dict: dict, children: children?.map { $0.deepCopy() })
    }

    public var type: String? { dict["WebBookmarkType"] as? String }
    public var uuid: String? { dict["WebBookmarkUUID"] as? String }
    public var isList: Bool { type == "WebBookmarkTypeList" }
    public var isLeaf: Bool { type == "WebBookmarkTypeLeaf" }

    public var title: String {
        get {
            if isLeaf { return ((dict["URIDictionary"] as? [String: Any])?["title"] as? String) ?? "" }
            return (dict["Title"] as? String) ?? ""
        }
        set {
            if isLeaf {
                var u = (dict["URIDictionary"] as? [String: Any]) ?? [:]
                u["title"] = newValue
                dict["URIDictionary"] = u
            } else {
                dict["Title"] = newValue
            }
        }
    }

    public var url: String? {
        get { dict["URLString"] as? String }
        set { dict["URLString"] = newValue }
    }

    public enum Kind: String {
        case folder, bookmark, special
        case readonlyBookmark
    }

    /// Only plain folders and bookmarks with a UUID are ever synced or modified.
    public var kind: Kind {
        if isList {
            if dict["WebBookmarkIdentifier"] != nil || uuid == nil { return .special }
            return .folder
        }
        if isLeaf {
            guard url != nil else { return .special }
            return uuid == nil ? .readonlyBookmark : .bookmark
        }
        return .special
    }

    public var isSyncable: Bool { kind == .folder || kind == .bookmark }

    public func contains(_ other: PlistNode) -> Bool {
        if self === other { return true }
        for c in children ?? [] where c.contains(other) { return true }
        return false
    }

    public func walk(_ body: (PlistNode, PlistNode?) -> Void, parent: PlistNode? = nil) {
        body(self, parent)
        for c in children ?? [] { c.walk(body, parent: self) }
    }

    static func newLeaf(uuid: String, title: String, url: String) -> PlistNode {
        PlistNode(dict: [
            "WebBookmarkType": "WebBookmarkTypeLeaf",
            "WebBookmarkUUID": uuid,
            "URLString": url,
            "URIDictionary": ["title": title],
        ], children: nil)
    }

    static func newList(uuid: String, title: String) -> PlistNode {
        PlistNode(dict: [
            "WebBookmarkType": "WebBookmarkTypeList",
            "WebBookmarkUUID": uuid,
            "Title": title,
        ], children: [])
    }
}
