import XCTest
@testable import AgentCore

/// Safari changes reach the agent by file events alone (no timer), metadata-only rewrites
/// are ignored, and the shadow check reports what events missed.
final class AgentWatchTests: XCTestCase {
    private var dir: URL!
    private var file: URL { dir.appendingPathComponent("Bookmarks.plist") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("aw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try write(makeFixture())
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func write(_ plist: [String: Any]) throws {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: file, options: .atomic)
    }

    /// The fixture with the loose top-level bookmark renamed (a change the engine sees).
    private func renamed(_ title: String) -> [String: Any] {
        var p = makeFixture()
        var kids = p["Children"] as! [[String: Any]]
        kids[3]["URIDictionary"] = ["title": title]
        p["Children"] = kids
        return p
    }

    /// The fixture with only Safari's own sync metadata changed.
    private func metadataOnly() -> [String: Any] {
        var p = makeFixture()
        p["Sync"] = ["CloudKitDeviceIdentifier": "other-device"]
        return p
    }

    private func makeAgent() -> (Agent, () -> [String]) {
        let agent = Agent(safari: SafariStore(url: file),
                          state: StateStore(url: dir.appendingPathComponent("state.json"), historyDir: dir.appendingPathComponent("h")),
                          socketPath: dir.appendingPathComponent("unused.sock").path)
        let lock = NSLock()
        var events: [String] = []
        agent.broadcastObserver = { e in
            if let name = e["event"] as? String, name == "safari.changed" { lock.lock(); events.append(name); lock.unlock() }
        }
        return (agent, { lock.lock(); defer { lock.unlock() }; return events })
    }

    private func wait(until done: () -> Bool, timeout: TimeInterval = 3) {
        let end = Date().addingTimeInterval(timeout)
        while !done() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    func testFileEventsAloneReportChangesAndSkipMetadataRewrites() throws {
        let (agent, events) = makeAgent()
        agent.startWatcher()
        agent.work.sync {} // baseline taken

        try write(metadataOnly())
        Thread.sleep(forTimeInterval: 1.2) // past the event settle delay
        agent.work.sync {}
        XCTAssertEqual(events(), [], "a metadata-only rewrite is not a bookmarks change")

        try write(renamed("改了名字"))
        wait(until: { !events().isEmpty })
        XCTAssertEqual(events(), ["safari.changed"])
    }

    func testShadowCheckReportsWhatEventsMissed() throws {
        let (agent, _) = makeAgent()
        agent.work.sync { agent.tick() } // a baseline, but no watcher: every change is "missed"
        XCTAssertNil(agent.work.sync { agent.shadowCheck() })

        try write(metadataOnly())
        XCTAssertEqual(agent.work.sync { agent.shadowCheck() }, "a metadata-only rewrite")
        try write(renamed("又改了"))
        XCTAssertEqual(agent.work.sync { agent.shadowCheck() }, "a bookmarks change")
        XCTAssertNil(agent.work.sync { agent.shadowCheck() }, "each miss is logged once")
    }
}
