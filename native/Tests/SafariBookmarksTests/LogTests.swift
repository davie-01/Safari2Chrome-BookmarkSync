import XCTest
@testable import AgentCore

final class LogTests: XCTestCase {
    func testRotatesWhileWriting() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("log-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let log = Log()
        log.directory = dir
        log.open(name: "t")
        let line = String(repeating: "x", count: 1000)
        for _ in 0..<5000 { log.write("INFO", line) } // ~5 MB through one open handle
        let size = { (n: String) in (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(n).path))?[.size] as? Int ?? 0 }
        XCTAssertLessThanOrEqual(size("t.log"), Log.maxBytes)
        XCTAssertGreaterThan(size("t.1.log"), Log.maxBytes / 2)
        XCTAssertLessThanOrEqual(size("t.1.log"), Log.maxBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), ["t.1.log", "t.log"])
    }

    /// Two writers on one file (two processes) must not write over each other's lines.
    func testTwoWritersKeepEveryLine() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("log-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let a = Log(), b = Log()
        for l in [a, b] { l.directory = dir; l.open(name: "t") }
        for i in 0..<200 { a.write("INFO", "a\(i)"); b.write("INFO", "b\(i)") }
        let lines = try String(contentsOf: dir.appendingPathComponent("t.log"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 400)
        XCTAssertTrue(lines.allSatisfy { $0.contains(" INFO a") || $0.contains(" INFO b") })
    }
}
