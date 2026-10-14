import Foundation

// MARK: - Normalized tree (the JSON shape the extension's engine consumes)

public struct NormNode: Codable, Equatable {
    public var id: String
    public var kind: String            // folder | bookmark | special
    public var title: String
    public var url: String?
    public var children: [NormNode]?
    public var readonly: Bool?

    public init(id: String, kind: String, title: String, url: String? = nil, children: [NormNode]? = nil, readonly: Bool? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.url = url; self.children = children; self.readonly = readonly
    }
}

public struct NormTree: Codable, Equatable {
    public var roots: [String: NormNode]
}

public struct TreeStats: Codable, Equatable {
    public var folders = 0
    public var bookmarks = 0
    public var special = 0
    public var readonly = 0
    public var unsyncedMenuItems = 0
}

// MARK: - Ops (wire format produced by extension/engine/plan.js)

public enum Anchor: Equatable {
    case end
    case first
    case after(String)
}

public struct OpExpect: Codable, Equatable {
    public var kind: String?
    public var title: String?
    public var url: String?
    public init(kind: String? = nil, title: String? = nil, url: String? = nil) {
        self.kind = kind; self.title = title; self.url = url
    }
}

public struct SafariOp: Decodable, Equatable {
    public var op: String
    public var id: String
    public var kind: String?
    public var title: String?
    public var url: String?
    public var parent: String?
    public var after: Anchor
    public var expect: OpExpect?

    enum CodingKeys: String, CodingKey { case op, id, kind, title, url, parent, after, expect }

    public init(op: String, id: String, kind: String? = nil, title: String? = nil, url: String? = nil,
                parent: String? = nil, after: Anchor = .end, expect: OpExpect? = nil) {
        self.op = op; self.id = id; self.kind = kind; self.title = title; self.url = url
        self.parent = parent; self.after = after; self.expect = expect
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        op = try c.decode(String.self, forKey: .op)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        parent = try c.decodeIfPresent(String.self, forKey: .parent)
        expect = try c.decodeIfPresent(OpExpect.self, forKey: .expect)
        if !c.contains(.after) {
            after = .end
        } else if try c.decodeNil(forKey: .after) {
            after = .first
        } else {
            let s = try c.decode(String.self, forKey: .after)
            after = s == "END" ? .end : .after(s)
        }
    }
}

// MARK: - Document

public final class SafariDocument {
    public static let barTitle = "BookmarksBar"
    public static let menuTitle = "BookmarksMenu"
    public static let rootKeys = ["root:bar", "root:other"]

    public private(set) var root: PlistNode
    public let format: PropertyListSerialization.PropertyListFormat

    public init(data: Data) throws {
        var fmt = PropertyListSerialization.PropertyListFormat.binary
        let obj: Any
        do {
            obj = try PropertyListSerialization.propertyList(from: data, options: [], format: &fmt)
        } catch {
            throw SafariBookmarkError.malformed("cannot decode plist: \(error.localizedDescription)")
        }
        root = try PlistNode(plist: obj)
        format = fmt
        guard root.isList else { throw SafariBookmarkError.malformed("top level is not a list") }
        for k in Self.rootKeys { _ = try rootNode(k) }
    }

    private init(root: PlistNode, format: PropertyListSerialization.PropertyListFormat) {
        self.root = root
        self.format = format
    }

    public func copy() -> SafariDocument { SafariDocument(root: root.deepCopy(), format: format) }

    public func serialize() throws -> Data {
        let fmt: PropertyListSerialization.PropertyListFormat = (format == .openStep) ? .xml : format
        return try PropertyListSerialization.data(fromPropertyList: root.toPlist(), format: fmt, options: 0)
    }

    public func rootNode(_ key: String) throws -> PlistNode {
        switch key {
        case "root:bar":
            guard let n = root.children?.first(where: { $0.isList && ($0.dict["Title"] as? String) == Self.barTitle }) else {
                throw SafariBookmarkError.rootNotFound(Self.barTitle)
            }
            return n
        case "root:other":
            // Items placed directly at Safari's top level (shown loose in the sidebar).
            return root
        default:
            throw SafariBookmarkError.rootNotFound(key)
        }
    }

    /// Top-level system containers: 个人收藏, 书签菜单, 阅读列表, 历史记录 proxy, anything
    /// with an identifier or hidden from the UI. Never synced, moved or edited as nodes.
    public static func isTopContainer(_ n: PlistNode) -> Bool {
        if !n.isList && !n.isLeaf { return true }
        if n.dict["WebBookmarkIdentifier"] != nil || n.dict["ShouldOmitFromUI"] != nil { return true }
        if n.isList, let t = n.dict["Title"] as? String, [barTitle, menuTitle, "com.apple.ReadingList"].contains(t) { return true }
        return false
    }

    /// Syncable direct children of a root key's container.
    func isRootLevelLoose(_ n: PlistNode) -> Bool { !Self.isTopContainer(n) }

    /// Number of items in 书签菜单 (not synced; reported so the UI can say so).
    public var bookmarksMenuItemCount: Int {
        guard let m = root.children?.first(where: { $0.isList && ($0.dict["Title"] as? String) == Self.menuTitle }) else { return 0 }
        var c = 0
        m.walk { _, p in if p != nil { c += 1 } }
        return c
    }

    // MARK: normalize

    public func normalized() throws -> (tree: NormTree, stats: TreeStats) {
        var stats = TreeStats()
        var seen = Set<String>()
        func conv(_ n: PlistNode, path: String) -> NormNode {
            var kind = n.kind
            var id = n.uuid ?? "noid:\(path)"
            var readonly: Bool? = nil
            if let u = n.uuid {
                if seen.contains(u) { id = "dup:\(u):\(path)"; readonly = true } // never touch duplicates
                seen.insert(u)
            }
            if kind == .readonlyBookmark { readonly = true; kind = .bookmark }
            switch kind {
            case .folder:
                if readonly == true { stats.readonly += 1 } else { stats.folders += 1 }
                let kids = (n.children ?? []).enumerated().map { conv($0.element, path: "\(path).\($0.offset)") }
                return NormNode(id: id, kind: "folder", title: n.title, children: kids, readonly: readonly)
            case .bookmark:
                if readonly == true { stats.readonly += 1 } else { stats.bookmarks += 1 }
                return NormNode(id: id, kind: "bookmark", title: n.title, url: n.url ?? "", readonly: readonly)
            default:
                stats.special += 1
                return NormNode(id: n.uuid.map { "special:\($0)" } ?? "special:\(path)", kind: "special", title: n.title)
            }
        }
        var roots: [String: NormNode] = [:]
        for key in Self.rootKeys {
            let r = try rootNode(key)
            let kids: [NormNode] = (r.children ?? []).enumerated().map { (i, ch) in
                if key == "root:other" && Self.isTopContainer(ch) {
                    return NormNode(id: "special:top:\(i)", kind: "special", title: ch.title)
                }
                return conv(ch, path: "\(key).\(i)")
            }
            roots[key] = NormNode(id: key, kind: "folder", title: key == "root:other" ? "Safari 顶层" : r.title, children: kids)
        }
        stats.unsyncedMenuItems = bookmarksMenuItemCount
        return (NormTree(roots: roots), stats)
    }

    // MARK: apply ops

    /// Applies ops in order. Mutates this document; callers work on `copy()` so a failure
    /// leaves the original intact. Returns the set of UUIDs touched (for fidelity checks).
    @discardableResult
    public func apply(_ ops: [SafariOp]) throws -> Set<String> {
        let bar = try rootNode("root:bar")
        let top = root
        var nodeOf: [String: PlistNode] = [:]
        var parentOf: [String: PlistNode] = [:]
        var allUUIDs = Set<String>()
        var dupes = Set<String>()
        root.walk { n, _ in
            if let u = n.uuid { if !allUUIDs.insert(u).inserted { dupes.insert(u) } }
        }
        let index: (PlistNode) -> Void = { r in
            r.walk { n, p in
                guard let p = p, let u = n.uuid else { return }
                nodeOf[u] = n
                parentOf[u] = p
            }
        }
        index(bar)
        for ch in top.children ?? [] where !Self.isTopContainer(ch) {
            if let u = ch.uuid { nodeOf[u] = ch; parentOf[u] = top }
            index(ch)
        }

        func folder(_ id: String?) throws -> PlistNode {
            guard let id = id else { throw SafariBookmarkError.invalidOp("missing parent") }
            if id == "root:bar" { return bar }
            if id == "root:other" { return top }
            guard let n = nodeOf[id], n.kind == .folder, !dupes.contains(id) else {
                throw SafariBookmarkError.precondition("parent folder \(id) not found")
            }
            return n
        }
        func syncNode(_ id: String) throws -> PlistNode {
            guard let n = nodeOf[id] else { throw SafariBookmarkError.precondition("node \(id) not found") }
            guard n.isSyncable, !dupes.contains(id) else { throw SafariBookmarkError.invalidOp("node \(id) is not modifiable") }
            return n
        }
        func insert(_ node: PlistNode, into p: PlistNode, _ anchor: Anchor) throws {
            var kids = p.children ?? []
            switch anchor {
            case .end: kids.append(node)
            case .first:
                // before the first syncable sibling (keeps system containers / proxies where they are)
                let i = kids.firstIndex(where: { $0 !== node && $0.isSyncable && !(p === root && Self.isTopContainer($0)) }) ?? kids.count
                kids.insert(node, at: i)
            case .after(let a):
                guard let i = kids.firstIndex(where: { $0.uuid == a && $0 !== node }) else {
                    throw SafariBookmarkError.precondition("anchor \(a) not in parent")
                }
                kids.insert(node, at: i + 1)
            }
            p.children = kids
        }
        func detach(_ node: PlistNode, id: String) {
            guard let p = parentOf[id] else { return }
            p.children?.removeAll { $0 === node }
        }
        func checkExpect(_ n: PlistNode, _ e: OpExpect?) throws {
            guard let e = e else { return }
            if let k = e.kind, k != (n.kind == .folder ? "folder" : "bookmark") { throw SafariBookmarkError.precondition("kind changed") }
            if let t = e.title, t != n.title { throw SafariBookmarkError.precondition("title changed") }
            if let u = e.url, u != (n.url ?? "") { throw SafariBookmarkError.precondition("url changed") }
        }

        var touched = Set<String>()
        for op in ops {
            switch op.op {
            case "create":
                guard !allUUIDs.contains(op.id) else { throw SafariBookmarkError.invalidOp("uuid \(op.id) already exists") }
                guard UUID(uuidString: op.id) != nil else { throw SafariBookmarkError.invalidOp("bad uuid \(op.id)") }
                let p = try folder(op.parent)
                let node: PlistNode
                switch op.kind {
                case "folder": node = PlistNode.newList(uuid: op.id, title: op.title ?? "")
                case "bookmark":
                    guard let u = op.url, !u.isEmpty else { throw SafariBookmarkError.invalidOp("bookmark without url") }
                    node = PlistNode.newLeaf(uuid: op.id, title: op.title ?? "", url: u)
                default: throw SafariBookmarkError.invalidOp("bad kind \(op.kind ?? "nil")")
                }
                try insert(node, into: p, op.after)
                nodeOf[op.id] = node
                parentOf[op.id] = p
                allUUIDs.insert(op.id)
            case "update":
                let n = try syncNode(op.id)
                try checkExpect(n, op.expect)
                if let t = op.title { n.title = t }
                if let u = op.url {
                    guard n.isLeaf else { throw SafariBookmarkError.invalidOp("url on folder") }
                    n.url = u
                }
            case "move":
                let n = try syncNode(op.id)
                let dest = try folder(op.parent)
                if n.contains(dest) { throw SafariBookmarkError.invalidOp("move into own subtree") }
                detach(n, id: op.id)
                try insert(n, into: dest, op.after)
                parentOf[op.id] = dest
            case "remove":
                let n = try syncNode(op.id)
                try checkExpect(n, op.expect)
                detach(n, id: op.id)
                n.walk { x, _ in
                    if let u = x.uuid { nodeOf.removeValue(forKey: u); parentOf.removeValue(forKey: u); touched.insert(u) }
                }
            default:
                throw SafariBookmarkError.invalidOp("unknown op \(op.op)")
            }
            touched.insert(op.id)
        }
        return touched
    }

    // MARK: fidelity

    /// Everything that no op touched must be byte-for-byte equal as a plist value:
    /// top-level dict, all non-bar/menu top-level children (History proxy, Reading List,
    /// ...), and every untouched node's own dictionary inside bar/menu.
    public static func fidelityProblems(original: SafariDocument, modified: SafariDocument, touched: Set<String>) -> [String] {
        var problems: [String] = []
        func eq(_ a: [String: Any], _ b: [String: Any]) -> Bool { NSDictionary(dictionary: a).isEqual(to: b) }

        if !eq(original.root.dict, modified.root.dict) { problems.append("top-level dictionary changed") }
        let oTop = (original.root.children ?? []).filter(Self.isTopContainer)
        let mTop = (modified.root.children ?? []).filter(Self.isTopContainer)
        if oTop.count != mTop.count { problems.append("top-level container count changed") }
        for (a, b) in zip(oTop, mTop) {
            if a.isList && (a.dict["Title"] as? String) == Self.barTitle {
                if !eq(a.dict, b.dict) { problems.append("个人收藏 container dictionary changed") }
                continue
            }
            if !NSDictionary(dictionary: a.toPlist()).isEqual(to: b.toPlist()) {
                problems.append("unsynced top-level item \(a.title) changed")
            }
        }

        func collect(_ doc: SafariDocument) -> (byUUID: [String: PlistNode], special: [[String: Any]]) {
            var byUUID: [String: PlistNode] = [:]
            var special: [[String: Any]] = []
            let visit: (PlistNode, PlistNode?) -> Void = { n, p in
                guard p != nil else { return }
                if let u = n.uuid, n.isSyncable { byUUID[u] = n } else { special.append(n.toPlist()) }
            }
            if let bar = try? doc.rootNode("root:bar") { bar.walk(visit) }
            for ch in doc.root.children ?? [] where !Self.isTopContainer(ch) {
                if let u = ch.uuid, ch.isSyncable { byUUID[u] = ch } else { special.append(ch.toPlist()) }
                for g in ch.children ?? [] { g.walk(visit, parent: ch) }
            }
            return (byUUID, special)
        }
        let o = collect(original), m = collect(modified)
        for (u, n) in o.byUUID where !touched.contains(u) {
            guard let n2 = m.byUUID[u] else { problems.append("untouched node \(u) disappeared"); continue }
            if !eq(n.dict, n2.dict) { problems.append("untouched node \(u) changed") }
        }
        for u in m.byUUID.keys where o.byUUID[u] == nil && !touched.contains(u) {
            problems.append("unexpected new node \(u)")
        }
        if o.special.count != m.special.count { problems.append("special node count changed") }
        else {
            var pool = m.special
            for s in o.special {
                if let i = pool.firstIndex(where: { NSDictionary(dictionary: $0).isEqual(to: s) }) { pool.remove(at: i) }
                else { problems.append("special node changed"); break }
            }
        }
        return problems
    }
}
