import XCTest
@testable import AgentCore

final class AgentStartPolicyTests: XCTestCase {
    private func next(_ downFor: TimeInterval, nudged: Bool = false, resident: Bool = true) -> AgentStartPolicy.Action {
        AgentStartPolicy.next(residentEnabled: resident, downFor: downFor, nudged: nudged)
    }

    func testResidentRestartDoesNotStartATemporaryAgent() {
        XCTAssertEqual(next(0), .wait) // launchd is on it
        XCTAssertEqual(next(1), .nudgeResident)
        XCTAssertEqual(next(1, nudged: true), .wait)
        XCTAssertEqual(next(11.9, nudged: true), .wait) // still within launchd's throttle
    }

    func testResidentThatCannotStartFallsBackToATemporaryAgent() {
        XCTAssertEqual(next(12, nudged: true), .startTemporary)
        XCTAssertEqual(next(14), .startTemporary)
    }

    func testResidentOffStartsATemporaryAgentAtOnce() {
        XCTAssertEqual(next(0, resident: false), .startTemporary)
    }

    /// The real backoff has to reach the fallback, and in the order above.
    func testAppRetriesReachTheFallback() {
        var at: TimeInterval = 0
        var actions = [next(at)]
        var nudged = false
        for step in [1.0, 3, 10] {
            at += step
            let a = next(at, nudged: nudged)
            if a == .nudgeResident { nudged = true }
            actions.append(a)
        }
        XCTAssertEqual(actions, [.wait, .nudgeResident, .wait, .startTemporary])
    }

    func testTemporaryAgentDoesNotInheritTheShadowSwitch() {
        let env = AgentStartPolicy.temporaryEnvironment(["BMSYNC_SHADOW_POLL": "1", "HOME": "/h"])
        XCTAssertEqual(env, ["HOME": "/h"])
    }
}
