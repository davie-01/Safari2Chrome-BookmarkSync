import XCTest
@testable import AgentCore

final class AutoScheduleTests: XCTestCase {
    private func ok(_ v: [String: Any]) -> Result<Any?, AgentError> { .success(v) }

    func testOutcomeOfEngineReplies() {
        // the engine reports most failures inside a successful reply
        XCTAssertEqual(Agent.autoOutcome(ok(["skipped": "busy"])), .transient)
        XCTAssertEqual(Agent.autoOutcome(ok(["skipped": "nothing", "pending": 3])), .done)
        XCTAssertEqual(Agent.autoOutcome(ok(["ok": true, "remaining": 2])), .done)
        XCTAssertEqual(Agent.autoOutcome(ok(["ok": false, "errors": [["code": "changedSinceScan", "message": "x"]]])), .transient)
        XCTAssertEqual(Agent.autoOutcome(ok(["ok": false, "errors": [["code": "staleState", "message": "x"]]])), .transient)
        XCTAssertEqual(Agent.autoOutcome(ok(["ok": false, "errors": [["ep": "cr-1", "code": "timeout"]]])), .transient)
        // a Chrome write that stopped part-way carries no code
        XCTAssertEqual(Agent.autoOutcome(ok(["ok": false, "errors": [["ep": "cr-1", "message": "precondition: title changed", "index": 2]]])), .transient)
        XCTAssertEqual(Agent.autoOutcome(ok(["ok": false, "errors": [["ep": "safari", "code": "verifyFailed"]]])), .failed)
        // one permanent error among transient ones: retrying would not help
        XCTAssertEqual(Agent.autoOutcome(ok(["ok": false, "errors": [["code": "timeout"], ["code": "noFullDiskAccess"]]])), .failed)
        XCTAssertEqual(Agent.autoOutcome(ok(["ok": false])), .failed)
        XCTAssertEqual(Agent.autoOutcome(.success(nil)), .failed)
        XCTAssertEqual(Agent.autoOutcome(.failure(AgentError("busy", "x"))), .transient)
        XCTAssertEqual(Agent.autoOutcome(.failure(AgentError("engineUnavailable", "x"))), .failed)
    }

    func testNextStep() {
        XCTAssertEqual(Agent.nextAuto(.done, changedMeanwhile: false, retries: 0), .idle)
        XCTAssertEqual(Agent.nextAuto(.failed, changedMeanwhile: false, retries: 0), .idle)
        // changes during the run win over everything: run again for them
        XCTAssertEqual(Agent.nextAuto(.done, changedMeanwhile: true, retries: 0), .again)
        XCTAssertEqual(Agent.nextAuto(.transient, changedMeanwhile: true, retries: 4), .again)
        // transient failures back off, then stop until the next change
        XCTAssertEqual(Agent.nextAuto(.transient, changedMeanwhile: false, retries: 0), .retry(after: 5))
        XCTAssertEqual(Agent.nextAuto(.transient, changedMeanwhile: false, retries: 3), .retry(after: 40))
        XCTAssertEqual(Agent.nextAuto(.transient, changedMeanwhile: false, retries: 5, maxRetries: 5), .giveUp)
    }
}
