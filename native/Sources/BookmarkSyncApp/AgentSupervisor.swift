import Foundation
import AgentCore

/// Keeps an agent available while the app is open.
///
/// Resident mode on  → launchd owns the agent; this class only steps in if it cannot start.
/// Resident mode off → the app runs one as a child process and kills it on quit, so syncing
/// works while the app is open and nothing stays behind afterwards. The agent itself holds a
/// lock, so a temporary one can never take the socket from the resident one.
final class AgentSupervisor {
    static let shared = AgentSupervisor()
    private var child: Process?
    /// Write end of the temporary agent's stdin, never written: when this process ends the
    /// kernel closes it and the agent sees end of file and exits (no polling on either side).
    private var lifeline: Pipe?
    private let lock = NSLock()

    var temporaryRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return child?.isRunning ?? false
    }

    /// When the agent we are waiting for went away, and whether launchd was nudged since.
    private var downSince: Date?
    private var nudged = false

    /// Does what the current outage calls for (see AgentStartPolicy). The caller retries with
    /// backoff and the socket's appearance wakes it sooner. May block on launchctl: call it off
    /// the main thread.
    func ensureRunning() {
        if agentReachable() {
            lock.lock(); downSince = nil; nudged = false; lock.unlock()
            return
        }
        lock.lock()
        let now = Date()
        if downSince == nil { downSince = now; nudged = false }
        let action = AgentStartPolicy.next(residentEnabled: Installer.residentEnabled,
                                           downFor: now.timeIntervalSince(downSince ?? now), nudged: nudged)
        if action == .nudgeResident { nudged = true }
        lock.unlock()
        switch action {
        case .wait: break
        case .nudgeResident: Installer.kickstartResident() // an upgrade can leave a stale service record
        case .startTemporary: startTemporary() // the agent's lock keeps the two from clashing
        }
    }

    func agentReachable() -> Bool {
        guard let fd = connectUnix(Paths.socket.path) else { return false }
        close(fd)
        return true
    }

    private func startTemporary() {
        lock.lock()
        if child?.isRunning == true { lock.unlock(); return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Installer.helperPath)
        p.arguments = ["agent", "--exit-with-parent"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardInput = pipe
        p.environment = AgentStartPolicy.temporaryEnvironment(ProcessInfo.processInfo.environment)
        do {
            try p.run()
            child = p
            lifeline = pipe
            lock.unlock()
            Log.info("app started a temporary agent pid=\(p.processIdentifier)")
        } catch {
            lock.unlock()
            Log.warn("cannot start temporary agent: \(error.localizedDescription)")
        }
        // no wait here: the app connects when the agent's socket appears
    }

    func stopTemporary() {
        lock.lock()
        let p = child
        child = nil
        lifeline = nil
        lock.unlock()
        guard let p = p, p.isRunning else { return }
        p.terminate()
        let deadline = Date().addingTimeInterval(2)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }

    func restartTemporary() {
        stopTemporary()
        if !Installer.residentEnabled { startTemporary() }
    }
}
