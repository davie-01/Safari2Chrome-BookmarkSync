import Foundation
import AgentCore

/// Keeps an agent available while the app is open.
///
/// Resident mode on  → launchd owns the agent; this class only repairs it if it stays down.
/// Resident mode off → the app runs one as a child process and kills it on quit, so syncing
/// works while the app is open and nothing stays behind afterwards.
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

    /// When the agent we are waiting for went away, and the repair steps taken since.
    private var downSince: Date?
    private var tried = 0

    /// Does what the current outage calls for (see AgentStartPolicy) and returns what the user
    /// should be told, if anything. The caller retries with backoff and the socket's appearance
    /// wakes it sooner. May block on launchctl: call it off the main thread.
    @discardableResult
    func ensureRunning() -> String? {
        if agentReachable() {
            forgetOutage()
            return nil
        }
        let state: AgentStartPolicy.ResidentState = Installer.residentNeedsApproval ? .needsApproval : Installer.residentEnabled ? .on : .off
        lock.lock()
        let now = Date()
        if downSince == nil { downSince = now; tried = 0 }
        let downFor = now.timeIntervalSince(downSince ?? now)
        let action = AgentStartPolicy.next(state, downFor: downFor, tried: tried)
        if action == .restartResident || action == .reregisterResident { tried += 1 }
        lock.unlock()
        switch action {
        case .wait: break
        case .restartResident: Installer.kickstartResident()
        case .reregisterResident:
            // an upgrade can leave a stale service record that only registering again clears
            Log.warn("resident agent still down after \(Int(downFor)) s: registering it again")
            do { Log.info(try Installer.setResident(true)) }
            catch { Log.warn("cannot register the resident agent: \(error.localizedDescription)") }
        case .startTemporary: startTemporary()
        case .reportNeedsApproval:
            return t("后台服务等待批准：请到 系统设置 → 通用 → 登录项与扩展 打开 BookmarkSync，或在「权限」页改为只在 App 打开时同步")
        case .reportCannotStart:
            Log.error("resident agent still down after \(Int(downFor)) s")
            return t("后台服务无法启动：请在「权限」页重启后台服务，或改为只在 App 打开时同步；详情见日志")
        }
        return nil
    }

    /// The next failure starts over: repair steps run again, for a user asking to retry.
    func forgetOutage() {
        lock.lock(); downSince = nil; tried = 0; lock.unlock()
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
