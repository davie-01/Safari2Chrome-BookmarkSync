import XCTest
@testable import AgentCore

final class FileWatcherTests: XCTestCase {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("fw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    /// Waits until the watcher has fired at least once after `action`.
    private func expectChange(_ hits: () -> Int, after action: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) rethrows {
        let before = hits()
        try action()
        let deadline = Date().addingTimeInterval(3)
        while hits() == before && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertGreaterThan(hits(), before, "no change event", file: file, line: line)
    }

    func testInPlaceWritesAndAtomicReplacesAndRecreation() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("Bookmarks.plist")
        try Data("a".utf8).write(to: url)
        let q = DispatchQueue(label: "fw.test")
        let lock = NSLock()
        var n = 0
        let w = FileWatcher(url: url, queue: q) { lock.lock(); n += 1; lock.unlock() }
        XCTAssertTrue(w.start())
        let hits = { () -> Int in lock.lock(); defer { lock.unlock() }; return n }

        // in place
        try expectChange(hits) {
            let h = try FileHandle(forWritingTo: url)
            try h.seekToEnd(); try h.write(contentsOf: Data("b".utf8)); try h.close()
        }
        // atomic replace (temp file + rename), twice: the watcher must follow the new file
        for i in 0..<2 { try expectChange(hits) { try Data("c\(i)".utf8).write(to: url, options: .atomic) } }
        try expectChange(hits) {
            let h = try FileHandle(forWritingTo: url)
            try h.seekToEnd(); try h.write(contentsOf: Data("d".utf8)); try h.close()
        }
        // deleted, then created again
        try expectChange(hits) { try FileManager.default.removeItem(at: url) }
        try expectChange(hits) { try Data("e".utf8).write(to: url) }
        try expectChange(hits) {
            let h = try FileHandle(forWritingTo: url)
            try h.seekToEnd(); try h.write(contentsOf: Data("f".utf8)); try h.close()
        }
        w.stop()
    }

    /// The app and the native host watch for the agent's socket: binding one is a folder event.
    func testSocketAppearing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fw\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("agent.sock").path
        let lock = NSLock()
        var n = 0
        let w = FileWatcher(url: URL(fileURLWithPath: path), queue: DispatchQueue(label: "fw.sock")) { lock.lock(); n += 1; lock.unlock() }
        XCTAssertTrue(w.start())
        let hits = { () -> Int in lock.lock(); defer { lock.unlock() }; return n }
        for _ in 0..<2 { // first start, then a restart that unlinks and binds again
            try expectChange(hits) {
                unlink(path)
                var addr = try unixAddress(path)
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
                XCTAssertEqual(r, 0)
                close(fd)
            }
        }
        w.stop()
    }

    func testUnwatchableFolder() {
        let w = FileWatcher(url: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/Bookmarks.plist"),
                            queue: DispatchQueue(label: "fw.test2")) {}
        XCTAssertFalse(w.start())
    }
}
