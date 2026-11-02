import Foundation

/// What the app does when it cannot reach an agent. launchd restarts the resident service by
/// itself, so a temporary agent started during that gap would take the lock and leave the
/// resident one failing with alreadyRunning, again every 10 s, until the app quits.
public enum AgentStartPolicy {
    public enum Action: Equatable { case wait, nudgeResident, startTemporary }

    /// launchd holds a respawn back by up to 10 s (its throttle interval).
    public static let residentGrace: TimeInterval = 12
    /// A plain restart is usually over by now; a nudge sooner would only interrupt it.
    public static let nudgeAfter: TimeInterval = 1

    public static func next(residentEnabled: Bool, downFor: TimeInterval, nudged: Bool) -> Action {
        guard residentEnabled else { return .startTemporary }
        if downFor >= residentGrace { return .startTemporary }
        return downFor >= nudgeAfter && !nudged ? .nudgeResident : .wait
    }

    /// A temporary agent is ordinary use: development switches the app happened to be launched
    /// with (launchctl setenv is not undone in running processes) must not carry over to it.
    public static func temporaryEnvironment(_ env: [String: String]) -> [String: String] {
        env.filter { $0.key != "BMSYNC_SHADOW_POLL" }
    }
}
