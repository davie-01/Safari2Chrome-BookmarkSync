import XCTest
@testable import AgentCore

final class PendingRepliesTests: XCTestCase {
    private let queue = DispatchQueue(label: "test.pending")
    private let late = AgentError("timeout", "no answer")

    func testAReplyAnswersOnceAndLateRepliesAreDropped() {
        let pending = PendingReplies(queue: queue)
        var calls = 0
        queue.sync {
            pending.add(1, timeout: 60, timedOut: late) { r in calls += 1; XCTAssertEqual((try? r.get()) as? Int, 7) }
            XCTAssertTrue(pending.resolve(1, .success(7)))
            XCTAssertFalse(pending.resolve(1, .success(8)))
            XCTAssertEqual(pending.count, 0)
        }
        XCTAssertEqual(calls, 1)
    }

    func testTheDeadlineAnswersWhenTheAgentDoesNot() {
        let pending = PendingReplies(queue: queue)
        let answered = expectation(description: "timed out")
        queue.sync {
            pending.add(1, timeout: 0.05, timedOut: late) { r in
                if case .failure(let e) = r { XCTAssertEqual(e.code, "timeout") } else { XCTFail("expected the timeout") }
                answered.fulfill()
            }
        }
        wait(for: [answered], timeout: 2)
        queue.sync { XCTAssertFalse(pending.resolve(1, .success(nil))) } // the reply came too late
    }

    func testAnsweredRequestsDoNotTimeOut() {
        let pending = PendingReplies(queue: queue)
        var calls = 0
        queue.sync {
            pending.add(1, timeout: 0.05, timedOut: late) { _ in calls += 1 }
            pending.resolve(1, .success(nil))
        }
        Thread.sleep(forTimeInterval: 0.2)
        queue.sync { XCTAssertEqual(calls, 1) }
    }

    func testFailAllAnswersEveryoneOnce() {
        let pending = PendingReplies(queue: queue)
        var codes: [String] = []
        queue.sync {
            for id in 1...3 { pending.add(id, timeout: 0.05, timedOut: late) { r in if case .failure(let e) = r { codes.append(e.code) } } }
            pending.failAll(AgentError("disconnected", "gone"))
        }
        Thread.sleep(forTimeInterval: 0.2)
        queue.sync { XCTAssertEqual(codes, ["disconnected", "disconnected", "disconnected"]) }
    }

    func testTimeoutsOutlastTheAgentsOwn() {
        XCTAssertGreaterThan(PendingReplies.timeout(for: "engine.run"), 300) // a browser may take 300 s to write
        XCTAssertGreaterThan(PendingReplies.timeout(for: "endpoint.rpc"), 180)
        XCTAssertEqual(PendingReplies.timeout(for: "hello"), 30)
    }

    func testSettingsPatchMergesNestedObjects() {
        let base: [String: Any] = ["autoSync": false, "endpoints": ["a": ["mode": "both", "enabled": true]]]
        let out = JSON.merging(base, ["autoSync": true, "endpoints": ["a": ["mode": "send"], "b": ["enabled": false]]])
        XCTAssertEqual(out["autoSync"] as? Bool, true)
        let eps = out["endpoints"] as? [String: [String: Any]]
        XCTAssertEqual(eps?["a"]?["mode"] as? String, "send")
        XCTAssertEqual(eps?["a"]?["enabled"] as? Bool, true)
        XCTAssertEqual(eps?["b"]?["enabled"] as? Bool, false)
    }
}

final class LineReaderTests: XCTestCase {
    /// Lines split across reads, several in one read, and one far larger than a read.
    func testLinesWhateverTheReads() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        let big = String(repeating: "x", count: 300_000)
        let writer = Thread {
            for part in ["a", "b\nc\nd", "\n", big, "\n", "e\n"] { _ = writeAll(fds[1], Data(part.utf8)) }
            close(fds[1])
        }
        writer.start()
        let reader = LineReader(fd: fds[0])
        var lines: [String] = []
        while let l = reader.next() { lines.append(String(decoding: l, as: UTF8.self)) }
        close(fds[0])
        XCTAssertEqual(lines, ["ab", "c", "d", big, "e"])
    }
}
