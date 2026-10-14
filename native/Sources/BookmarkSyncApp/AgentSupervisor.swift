import Foundation
import AgentCore

/// Keeps an agent available while the app is open.
///
/// Resident mode on  → launchd owns the agent; this class does nothing.
/// Resident mode off → the app runs one as a child process and kills it on quit, so syncing
/// works while the app is open and nothing stays behind afterwards. The agent itself holds a
/// lock, so a temporary one can never take the socket from the resident one.
final class AgentSupervisor {
    static let shared = AgentSupervisor()
    private var child: Process?
    private let lock = NSLock()

    var temporaryRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return child?.isRunning ?? false
    }

    /// Starts a temporary agent unless one is already reachable.
    private var kickstarted = false

    func ensureRunning() {
        if agentReachable() { return }
        if Installer.residentEnabled && !kickstarted {
            // launchd owns it; nudge it once (an upgrade can leave a stale service record).
            kickstarted = true
            Installer.kickstartResident()
            Thread.sleep(forTimeInterval: 1.0)
            if agentReachable() { return }
        }
        // Either resident is off, or the resident service cannot start: run one ourselves so
        // syncing works while the app is open. The agent's lock keeps the two from clashing.
        startTemporary()
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
        do {
            try p.run()
            child = p
            lock.unlock()
            Log.info("app started a temporary agent pid=\(p.processIdentifier)")
        } catch {
            lock.unlock()
            Log.warn("cannot start temporary agent: \(error.localizedDescription)")
        }
        // give it time to bind the socket before the first connect attempt
        Thread.sleep(forTimeInterval: 0.4)
    }

    func stopTemporary() {
        lock.lock()
        let p = child
        child = nil
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
