import XCTest
@testable import SafariBookmarks
@testable import AgentCore

/// Synthetic, Safari-shaped plist: History proxy, bar/menu with CloudKit-like Sync data,
/// unknown keys, Data/Date values, a Reading List. No real user data.
func makeFixture() -> [String: Any] {
    let sync: [String: Any] = ["ServerID": "srv-1", "Data": Data([1, 2, 3, 4])]
    func leaf(_ uuid: String, _ title: String, _ url: String, extra: [String: Any] = [:]) -> [String: Any] {
        var d: [String: Any] = [
            "WebBookmarkType": "WebBookmarkTypeLeaf",
            "WebBookmarkUUID": uuid,
            "URLString": url,
            "URIDictionary": ["title": title, "unknownSubKey": 7],
            "Sync": sync,
        ]
        for (k, v) in extra { d[k] = v }
        return d
    }
    func list(_ uuid: String?, _ title: String, _ kids: [[String: Any]], extra: [String: Any] = [:]) -> [String: Any] {
        var d: [String: Any] = ["WebBookmarkType": "WebBookmarkTypeList", "Title": title, "Children": kids]
        if let u = uuid { d["WebBookmarkUUID"] = u }
        for (k, v) in extra { d[k] = v }
        return d
    }
    return [
        "WebBookmarkType": "WebBookmarkTypeList",
        "WebBookmarkUUID": "00000000-0000-0000-0000-000000000000",
        "WebBookmarkFileVersion": 1,
        "Title": "",
        "Sync": ["CloudKitDeviceIdentifier": "dev"],
        "Children": [
            ["WebBookmarkType": "WebBookmarkTypeProxy", "Title": "History", "WebBookmarkIdentifier": "History",
             "WebBookmarkUUID": "11111111-0000-0000-0000-000000000001"],
            list("22222222-0000-0000-0000-000000000001", "BookmarksBar", [
                leaf("A0000000-0000-0000-0000-000000000001", "Apple", "https://www.apple.com/"),
                list("F0000000-0000-0000-0000-000000000001", "工作", [
                    leaf("A0000000-0000-0000-0000-000000000002", "Docs", "https://docs.test/a", extra: ["ExtraDate": Date(timeIntervalSince1970: 1_700_000_000)]),
                    leaf("A0000000-0000-0000-0000-000000000003", "Dup", "https://dup.test/"),
                    leaf("A0000000-0000-0000-0000-000000000004", "Dup", "https://dup.test/"),
                ], extra: ["Sync": sync, "FutureKey": ["x": true]]),
                ["WebBookmarkType": "WebBookmarkTypeProxy", "Title": "Odd proxy in bar"],
            ], extra: ["Sync": sync]),
            list("33333333-0000-0000-0000-000000000001", "BookmarksMenu", [
                leaf("A0000000-0000-0000-0000-000000000005", "Menu", "https://menu.test/"),
            ]),
            leaf("C0000000-0000-0000-0000-000000000001", "顶层书签", "https://loose.test/"),
            list("44444444-0000-0000-0000-000000000001", "com.apple.ReadingList", [
                leaf("B0000000-0000-0000-0000-000000000001", "Read later", "https://read.test/", extra: ["ReadingList": ["DateAdded": Date(timeIntervalSince1970: 1_600_000_000)]]),
            ], extra: ["ShouldOmitFromUI": true]),
        ],
    ]
}

func fixtureData() throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: makeFixture(), format: .binary, options: 0)
}

final class SafariDocumentTests: XCTestCase {
    func testNormalize() throws {
        let doc = try SafariDocument(data: fixtureData())
        let (tree, stats) = try doc.normalized()
        XCTAssertEqual(stats.folders, 1)
        XCTAssertEqual(stats.bookmarks, 5)          // 4 in 个人收藏 + 1 loose top-level
        XCTAssertEqual(stats.unsyncedMenuItems, 1)  // 书签菜单 is not synced
        let other = try XCTUnwrap(tree.roots["root:other"])
        XCTAssertEqual(other.children?.filter { $0.kind != "special" }.map(\.title), ["顶层书签"])
        let bar = try XCTUnwrap(tree.roots["root:bar"])
        XCTAssertEqual(bar.children?.map(\.kind), ["bookmark", "folder", "special"])
        XCTAssertEqual(bar.children?[1].title, "工作")
        XCTAssertEqual(bar.children?[1].children?.count, 3)
        XCTAssertNil(tree.roots["com.apple.ReadingList"])
    }

    func testRoundTripWithoutOpsIsLossless() throws {
        let data = try fixtureData()
        let doc = try SafariDocument(data: data)
        let out = try doc.serialize()
        let a = try PropertyListSerialization.propertyList(from: data, format: nil) as! NSDictionary
        let b = try PropertyListSerialization.propertyList(from: out, format: nil) as! NSDictionary
        XCTAssertEqual(a, b)
    }

    func testApplyAllOpKindsKeepsEverythingElse() throws {
        let original = try SafariDocument(data: fixtureData())
        let doc = original.copy()
        let newFolder = UUID().uuidString, newLeaf = UUID().uuidString
        let touched = try doc.apply([
            SafariOp(op: "create", id: newFolder, kind: "folder", title: "新建", parent: "root:other", after: .first),
            SafariOp(op: "create", id: newLeaf, kind: "bookmark", title: "N", url: "https://n.test/", parent: newFolder, after: .end),
            SafariOp(op: "update", id: "A0000000-0000-0000-0000-000000000001", title: "Apple!", expect: OpExpect(title: "Apple", url: "https://www.apple.com/")),
            SafariOp(op: "move", id: "A0000000-0000-0000-0000-000000000002", parent: "root:bar", after: .after("A0000000-0000-0000-0000-000000000001")),
            SafariOp(op: "remove", id: "A0000000-0000-0000-0000-000000000004", expect: OpExpect(kind: "bookmark", title: "Dup")),
        ])
        XCTAssertEqual(SafariDocument.fidelityProblems(original: original, modified: doc, touched: touched), [])
        let (tree, _) = try doc.normalized()
        let loose = tree.roots["root:other"]?.children?.filter { $0.kind != "special" }
        XCTAssertEqual(loose?.map(\.title), ["新建", "顶层书签"])
        XCTAssertEqual(loose?.first?.children?.first?.url, "https://n.test/")
        // system containers keep their order at the top
        XCTAssertEqual(doc.root.children?.prefix(3).map { $0.dict["Title"] as? String }, ["History", "BookmarksBar", "BookmarksMenu"])
        XCTAssertEqual(tree.roots["root:bar"]?.children?.map(\.title), ["Apple!", "Docs", "工作", "Odd proxy in bar"])
        // moved node keeps its unknown keys and Sync blob
        let moved = try doc.rootNode("root:bar").children![1]
        XCTAssertNotNil(moved.dict["ExtraDate"])
        XCTAssertNotNil(moved.dict["Sync"])
        // updated leaf keeps other URIDictionary keys
        let apple = try doc.rootNode("root:bar").children![0]
        XCTAssertEqual((apple.dict["URIDictionary"] as? [String: Any])?["unknownSubKey"] as? Int, 7)
        // serialize + parse again is identical in the synced view
        let again = try SafariDocument(data: doc.serialize())
        XCTAssertEqual(try again.normalized().tree, tree)
    }

    func testPreconditionFailureLeavesOriginalUntouched() throws {
        let original = try SafariDocument(data: fixtureData())
        let before = try original.normalized().tree
        let doc = original.copy()
        XCTAssertThrowsError(try doc.apply([
            SafariOp(op: "update", id: "A0000000-0000-0000-0000-000000000001", title: "x", expect: OpExpect(title: "stale")),
        ])) { e in XCTAssertEqual((e as? SafariBookmarkError)?.code, "precondition") }
        XCTAssertEqual(try original.normalized().tree, before)
    }

    func testRefusesSpecialNodesAndBadInput() throws {
        let doc = try SafariDocument(data: fixtureData()).copy()
        XCTAssertThrowsError(try doc.apply([SafariOp(op: "remove", id: "11111111-0000-0000-0000-000000000001")]))
        XCTAssertThrowsError(try doc.apply([SafariOp(op: "create", id: "A0000000-0000-0000-0000-000000000001", kind: "bookmark", title: "dup", url: "https://x/", parent: "root:bar")]))
        XCTAssertThrowsError(try doc.apply([SafariOp(op: "create", id: "not-a-uuid", kind: "bookmark", title: "x", url: "https://x/", parent: "root:bar")]))
        XCTAssertThrowsError(try doc.apply([SafariOp(op: "create", id: UUID().uuidString, kind: "bookmark", title: "x", url: "https://x/", parent: "44444444-0000-0000-0000-000000000001")]), "reading list is not a target")
        XCTAssertThrowsError(try doc.apply([SafariOp(op: "move", id: "22222222-0000-0000-0000-000000000001", parent: "root:other")]), "个人收藏 container cannot be moved")
        XCTAssertThrowsError(try doc.apply([SafariOp(op: "create", id: UUID().uuidString, kind: "bookmark", title: "x", url: "https://x/", parent: "33333333-0000-0000-0000-000000000001")]), "书签菜单 is not a target")
        XCTAssertThrowsError(try doc.apply([SafariOp(op: "move", id: "F0000000-0000-0000-0000-000000000001", parent: "F0000000-0000-0000-0000-000000000001")]))
    }

    func testOpDecoding() throws {
        let json = """
        [{"op":"move","id":"a","parent":"root:bar","after":null,"key":"k","item":"x","reorder":true},
         {"op":"move","id":"b","parent":"root:bar","after":"END"},
         {"op":"move","id":"c","parent":"root:bar"},
         {"op":"move","id":"d","parent":"root:bar","after":"ANCHOR"},
         {"op":"update","id":"e","title":"t","expect":{"title":"o","url":"u"}}]
        """
        let ops = try JSONDecoder().decode([SafariOp].self, from: Data(json.utf8))
        XCTAssertEqual(ops.map(\.after), [.first, .end, .end, .after("ANCHOR"), .end])
        XCTAssertEqual(ops[4].expect, OpExpect(title: "o", url: "u"))
    }

    func testFidelityDetectsCollateralChange() throws {
        let original = try SafariDocument(data: fixtureData())
        let doc = original.copy()
        try doc.rootNode("root:bar").children![0].dict["Sync"] = nil
        let problems = SafariDocument.fidelityProblems(original: original, modified: doc, touched: [])
        XCTAssertFalse(problems.isEmpty)
    }

    /// Same op semantics as the JS reference used by the engine tests.
    func testParityWithJSReference() throws {
        struct Case: Decodable { let name: String; let before: NormTree; let ops: [SafariOp]; let after: NormTree }
        let cases = try JSONDecoder().decode([Case].self, from: Data(parityFixturesJSON.utf8))
        XCTAssertGreaterThan(cases.count, 10)
        func strip(_ t: NormTree) -> NormTree {
            var t = t
            for (k, r) in t.roots { var r = r; r.children = r.children?.filter { $0.kind != "special" }; r.title = ""; t.roots[k] = r }
            return t
        }
        for c in cases {
            let doc = try SafariDocument(data: plist(from: c.before))
            try doc.apply(c.ops)
            XCTAssertEqual(strip(try doc.normalized().tree), strip(c.after), c.name)
        }
    }

    func plist(from tree: NormTree) throws -> Data {
        func conv(_ n: NormNode) -> [String: Any] {
            if n.kind == "folder" {
                return ["WebBookmarkType": "WebBookmarkTypeList", "WebBookmarkUUID": n.id, "Title": n.title,
                        "Children": (n.children ?? []).map(conv)]
            }
            return ["WebBookmarkType": "WebBookmarkTypeLeaf", "WebBookmarkUUID": n.id, "URLString": n.url ?? "",
                    "URIDictionary": ["title": n.title]]
        }
        let root: [String: Any] = [
            "WebBookmarkType": "WebBookmarkTypeList", "Title": "",
            "Children": [
                ["WebBookmarkType": "WebBookmarkTypeList", "Title": "BookmarksBar", "WebBookmarkUUID": "BAR",
                 "Children": (tree.roots["root:bar"]?.children ?? []).map(conv)],
                ["WebBookmarkType": "WebBookmarkTypeList", "Title": "BookmarksMenu", "WebBookmarkUUID": "MENU", "Children": []],
            ] + (tree.roots["root:other"]?.children ?? []).map(conv),
        ]
        return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }
}

final class StoreTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("bmsync-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("BMSYNC_SUPPORT_DIR", dir.appendingPathComponent("support").path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("BMSYNC_SUPPORT_DIR")
        try? FileManager.default.removeItem(at: dir)
    }

    func testApplyOnFileCopyWithBackupAndVerify() throws {
        let file = dir.appendingPathComponent("Bookmarks.plist")
        let original = try fixtureData()
        try original.write(to: file)
        let store = SafariStore(url: file)
        XCTAssertFalse(store.isRealSafariFile)
        let r = try store.apply([
            SafariOp(op: "create", id: UUID().uuidString, kind: "bookmark", title: "写入测试", url: "https://example.invalid/probe", parent: "root:bar", after: .end),
        ])
        XCTAssertEqual(r.applied, 1)
        let backup = try XCTUnwrap(r.backup)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: backup)), original)
        XCTAssertEqual(r.tree.roots["root:bar"]?.children?.last?.title, "写入测试")
        // Reading list survived byte-identical in value
        let after = try SafariDocument(data: Data(contentsOf: file))
        XCTAssertEqual(after.root.children?.count, 5)
        // stale precondition is refused and file untouched
        let fp = try store.read().fingerprint
        XCTAssertThrowsError(try store.apply([SafariOp(op: "update", id: "A0000000-0000-0000-0000-000000000001", title: "x", expect: OpExpect(title: "nope"))]))
        XCTAssertEqual(try store.read().fingerprint, fp)
    }

    func testStateStoreRevisions() throws {
        let s = StateStore(url: dir.appendingPathComponent("state.json"), historyDir: dir.appendingPathComponent("hist"))
        XCTAssertEqual(try s.load().revision, 0)
        let r1 = try s.save(["mappings": [:]], expectedRevision: 0)
        XCTAssertEqual(r1, 1)
        XCTAssertThrowsError(try s.save(["x": 1], expectedRevision: 0))
        XCTAssertEqual(try s.save(["x": 2], expectedRevision: 1), 2)
        XCTAssertEqual((try s.load().state as? [String: Any])?["x"] as? Int, 2)
    }

    func testChunkedFrames() throws {
        let small = Data(repeating: 65, count: 100)
        XCTAssertEqual(FrameWriter.frames(for: small).count, 1)
        let big = Data((0..<2_500_000).map { UInt8($0 % 251) })
        let frames = FrameWriter.frames(for: big)
        XCTAssertGreaterThan(frames.count, 1)
        var joined = Data()
        for f in frames {
            XCTAssertLessThan(f.count, NativeHost.maxFrame)
            let obj = try JSON.object(f)["chunk"] as! [String: Any]
            joined.append(Data(base64Encoded: obj["b64"] as! String)!)
        }
        XCTAssertEqual(joined, big)
    }
}
