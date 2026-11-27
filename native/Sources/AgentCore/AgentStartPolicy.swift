import Foundation

/// What the app does when it cannot reach an agent. The resident service belongs to launchd
/// alone: a temporary agent started beside it would take the lock and leave launchd's restarts
/// failing with alreadyRunning, every 10 s, until the app quits. So temporary agents exist only
/// when the user turned the resident service off; if it is on but down, the app repairs it or
/// says so.
public enum AgentStartPolicy {
    public enum ResidentState: Equatable { case off, on, needsApproval }
    public enum Action: Equatable { case wait, restartResident, reregisterResident, startTemporary, reportNeedsApproval, reportCannotStart }

    /// A plain restart is usually over by now; acting sooner would only interrupt it.
    public static let restartAfter: TimeInterval = 1
    /// launchd holds a respawn back by up to 10 s (its throttle interval).
    public static let reregisterAfter: TimeInterval = 12
    public static let giveUpAfter: TimeInterval = 30
    /// Registering the service again (an install, an upgrade) unregisters it first: for a
    /// moment it reads as off. Only an "off" that lasts is the user's choice.
    public static let offSettles: TimeInterval = 2

    /// `tried`: repair steps already taken in this outage. `offFor`: how long the service has
    /// read as off; infinite when that is known to be settled (the user just turned it off here,
    /// or the app has not seen an agent yet).
    public static func next(_ state: ResidentState, downFor: TimeInterval, tried: Int, offFor: TimeInterval = .infinity) -> Action {
        switch state {
        case .off: return offFor >= offSettles ? .startTemporary : .wait
        case .needsApproval: return .reportNeedsApproval
        case .on:
            switch tried {
            case 0: return downFor >= restartAfter ? .restartResident : .wait
            case 1: return downFor >= reregisterAfter ? .reregisterResident : .wait
            default: return downFor >= giveUpAfter ? .reportCannotStart : .wait
            }
        }
    }

    /// A temporary agent is ordinary use: development switches the app happened to be launched
    /// with (launchctl setenv is not undone in running processes) must not carry over to it.
    public static func temporaryEnvironment(_ env: [String: String]) -> [String: String] {
        env.filter { $0.key != "BMSYNC_SHADOW_POLL" }
    }
}
