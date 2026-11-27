import ServiceManagement
import XCTest
@testable import AgentCore

final class AgentStartPolicyTests: XCTestCase {
    private func next(_ downFor: TimeInterval, tried: Int = 0, _ state: AgentStartPolicy.ResidentState = .on) -> AgentStartPolicy.Action {
        AgentStartPolicy.next(state, downFor: downFor, tried: tried)
    }

    func testResidentOnNeverStartsATemporaryAgent() {
        for downFor in stride(from: 0.0, through: 600, by: 0.5) {
            for tried in 0...3 { XCTAssertNotEqual(next(downFor, tried: tried), .startTemporary) }
            XCTAssertNotEqual(next(downFor, .needsApproval), .startTemporary)
        }
    }

    func testRepairStepsInOrder() {
        XCTAssertEqual(next(0), .wait) // launchd is on it
        XCTAssertEqual(next(1), .restartResident)
        XCTAssertEqual(next(1, tried: 1), .wait)
        XCTAssertEqual(next(11.9, tried: 1), .wait) // still within launchd's throttle
        XCTAssertEqual(next(12, tried: 1), .reregisterResident)
        XCTAssertEqual(next(29, tried: 2), .wait)
        XCTAssertEqual(next(30, tried: 2), .reportCannotStart)
    }

    /// The app's real backoff has to get all the way to the report.
    func testAppRetriesReachTheReport() {
        var at: TimeInterval = 0, tried = 0
        var actions = [next(at)]
        for step in [1.0, 3, 10, 30] {
            at += step
            let a = next(at, tried: tried)
            if a == .restartResident || a == .reregisterResident { tried += 1 }
            actions.append(a)
        }
        XCTAssertEqual(actions, [.wait, .restartResident, .wait, .reregisterResident, .reportCannotStart])
    }

    /// A re-registration reads as off for a moment; a temporary agent started then would take
    /// the lock from the resident one coming up.
    func testABriefOffIsNotTheUsersChoice() {
        XCTAssertEqual(AgentStartPolicy.next(.off, downFor: 0, tried: 0, offFor: 0), .wait)
        XCTAssertEqual(AgentStartPolicy.next(.off, downFor: 1, tried: 0, offFor: 1.9), .wait)
        XCTAssertEqual(AgentStartPolicy.next(.off, downFor: 4, tried: 0, offFor: 2), .startTemporary)
    }

    func testOtherStates() {
        XCTAssertEqual(next(0, .off), .startTemporary)
        XCTAssertEqual(next(0, .needsApproval), .reportNeedsApproval) // launchd will not run it; repairing cannot help
    }

    /// Switched off in 登录项与扩展: the LaunchAgent would run anyway, against the user's choice.
    func testLaunchAgentOnlyWhenTheServiceCannotBeRegistered() {
        XCTAssertFalse(Installer.fallsBackToLaunchAgent(.requiresApproval))
        XCTAssertFalse(Installer.fallsBackToLaunchAgent(.enabled))
        XCTAssertTrue(Installer.fallsBackToLaunchAgent(.notRegistered))
        XCTAssertTrue(Installer.fallsBackToLaunchAgent(.notFound))
    }

    func testTemporaryAgentDoesNotInheritTheShadowSwitch() {
        let env = AgentStartPolicy.temporaryEnvironment(["BMSYNC_SHADOW_POLL": "1", "HOME": "/h"])
        XCTAssertEqual(env, ["HOME": "/h"])
    }
}

final class ExtensionIDTests: XCTestCase {
    /// A list saved before the store ID existed must not keep the store extension out.
    func testSavedIDsGainTheKnownOnes() {
        let ids = Installer.withKnownIDs(["dllnilcheahcklaiheddleegbdalbcjn"])
        XCTAssertTrue(ids.contains(Installer.defaultExtensionID))
        XCTAssertTrue(ids.contains("dllnilcheahcklaiheddleegbdalbcjn"))
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(Installer.withKnownIDs(["abc"]).first, "abc") // one added by hand stays
    }

    func testManifestKeyGivesTheStoreID() throws {
        let manifest = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("extension/manifest.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any]
        let der = try XCTUnwrap(Data(base64Encoded: json?["key"] as? String ?? ""))
        let hex = sha256Hex(der).prefix(32)
        let id = String(hex.map { c in Character(UnicodeScalar(UInt8(ascii: "a") + UInt8(c.hexDigitValue!))) })
        XCTAssertEqual(id, Installer.defaultExtensionID)
    }
}
