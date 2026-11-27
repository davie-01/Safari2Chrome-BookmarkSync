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
