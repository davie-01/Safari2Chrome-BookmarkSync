import AppKit
import AgentCore

/// The app's connection to the sync agent: one Unix-socket connection, newline-delimited
/// JSON, same protocol the browser extensions use. Reconnects on its own; when the resident
/// service is off, AgentSupervisor starts a temporary agent for as long as the app runs.
@MainActor
final class AgentLink: ObservableObject {
    static let shared = AgentLink()

    @Published private(set) var connected = false
    @Published private(set) var status: AgentStatus?
    @Published private(set) var pending: PendingInfo?
    @Published var settings = EngineSettings()
    @Published private(set) var settingsLoaded = false
    @Published private(set) var lastError: String?
    /// Why there is no agent, when that needs the user. Kept apart from lastError, which any
    /// failed call overwrites, and cleared only by a connection or a new attempt.
    @Published private(set) var connectionProblem: String?
    @Published private(set) var busy: String?
    @Published private(set) var lastMessage: String?
    /// The login item's state. Each read asks another process, so it is read off the main
    /// thread (refreshResident) and views use these copies.
    @Published private(set) var resident = false
    @Published private(set) var residentNeedsApproval = false
    @Published private(set) var residentChanging = false
    @Published var tab: AppTab = .sync
    /// False while the window is put away (⌘Q with the menu bar icon, or closed): the
    /// embedded web UI is then torn down instead of living on in the background.
    @Published var uiVisible = true
    @Published private(set) var lastRunAt: Date?
    @Published private(set) var storage: StorageStats?
    /// Bumped when the interface language changes, so the embedded web UI reloads.
    @Published private(set) var langToken = 0

    private var fd: Int32 = -1
    private var seq = 0
    private var pendingCalls: [Int: (Result<Any?, AgentError>) -> Void] = [:]
    /// Writes only; the read loop gets a thread of its own so it cannot block them.
    private let io = DispatchQueue(label: "bmsync.app.link.write")
    private var connecting = false
    private var connectedAt = Date.distantPast
    private var failures = 0
    private var retryTask: Task<Void, Never>?
    private var socketWatcher: FileWatcher?
    /// One-shot waits after failed attempts; after the last one, only events reconnect.
    private static let retrySteps: [Double] = [1, 3, 10, 30, 60, 60, 60, 60]
    /// The socket file appears at bind(), a moment before the agent listens: a connect
    /// refused right after the socket event is tried again a few times (about 3 s in all).
    /// These do not count as failures, so the socket appearing always reconnects.
    private static let settleWaits: [Double] = [0.05, 0.1, 0.2, 0.4, 0.8, 1.6]
    private var settling = false
    private struct EventSink {
        weak var owner: AnyObject?
        let fn: ([String: Any]) -> Void
    }
    private var eventSinks: [EventSink] = []
    private var refreshQueued = false

    var endpoints: [EndpointInfo] { status?.endpoints ?? [] }

    // MARK: connection
    //
    // Event-driven: an attempt is made at start, when the connection drops, when the agent's
    // socket appears (it binds a fresh one on every start), when the app becomes active, and
    // once after each failed attempt with a growing wait. Nothing runs while connected.

    func start() {
        try? Paths.ensureDir(Paths.support)
        let w = FileWatcher(url: Paths.socket, queue: DispatchQueue(label: "bmsync.app.socket-watch")) { [weak self] in
            Task { @MainActor in self?.socketAppeared() }
        }
        if !w.start() { Log.warn("cannot watch \(Paths.support.path); reconnecting on retries only") }
        socketWatcher = w
        // also when coming back from System Settings, where the login item may have changed
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.connect(); self?.refreshResident() }
        }
        refreshResident()
        connect()
    }

    func connect() {
        guard !connected, !connecting else { return }
        connecting = true
        retryTask?.cancel()
        retryTask = nil
        Task.detached(priority: .utility) { [weak self] in
            // may start or nudge the agent and wait for it: never on the main thread
            let problem = AgentSupervisor.shared.ensureRunning()
            let c = connectUnix(Paths.socket.path)
            await self?.finishConnect(c, problem)
        }
    }

    private func finishConnect(_ c: Int32?, _ problem: String?) {
        connecting = false
        guard let c = c else {
            if let problem = problem { report(problem) }
            retryLater()
            return
        }
        attach(c)
    }

    /// The agent (re)bound its socket, or something else changed in its folder.
    private func socketAppeared(attempt n: Int = 0) {
        guard !connected else { settling = false; return }
        if n == 0 { guard !settling else { return }; settling = true }
        Task.detached(priority: .utility) { [weak self] in
            let c = connectUnix(Paths.socket.path)
            await self?.finishSettle(c, attempt: n)
        }
    }

    private func finishSettle(_ c: Int32?, attempt n: Int) {
        if let c = c { settling = false; attach(c); return }
        guard n < AgentLink.settleWaits.count, !connected else { settling = false; return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(AgentLink.settleWaits[n] * 1_000_000_000))
            self?.socketAppeared(attempt: n + 1)
        }
    }

    private func attach(_ c: Int32) {
        if connected { close(c); return }
        retryTask?.cancel()
        retryTask = nil
        fd = c
        connected = true
        connectedAt = Date()
        lastError = nil
        connectionProblem = nil
        emit(["event": "agent.connected"])
        Thread.detachNewThread { [weak self] in
            let reader = LineReader(fd: c)
            while let line = reader.next() {
                guard let msg = try? JSON.object(line) else { continue }
                Task { @MainActor in self?.receive(msg) }
            }
            Task { @MainActor in self?.dropped(c) }
        }
        refresh()
    }

    private func report(_ problem: String) {
        guard problem != connectionProblem else { return }
        connectionProblem = problem
        emit(["event": "agent.disconnected"]) // the web UI shows it too
    }

    private func retryLater() {
        guard failures < AgentLink.retrySteps.count else {
            if connectionProblem == nil { report(t("后台服务无法启动；打开主窗口或重启后台服务后会再试")) }
            return
        }
        let wait = AgentLink.retrySteps[failures]
        failures += 1
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    /// `c`: the connection whose reader ended; a late reader of an older one is ignored.
    private func dropped(_ c: Int32? = nil) {
        if let c = c, c != fd { return }
        guard connected || fd >= 0 else { return }
        if fd >= 0 { close(fd); fd = -1 }
        connected = false
        status = nil
        emit(["event": "agent.disconnected"])
        for (_, cb) in pendingCalls { cb(.failure(AgentError("disconnected", t("与后台服务的连接断开")))) }
        pendingCalls = [:]
        // a connection that lasted is a restart: try at once; one that died young backs off
        if Date().timeIntervalSince(connectedAt) > 30 { failures = 0; connect() } else { retryLater() }
    }

    private func receive(_ msg: [String: Any]) {
        if let id = msg["id"] as? Int, let cb = pendingCalls.removeValue(forKey: id) {
            if msg["ok"] as? Bool == true { cb(.success(msg["result"])) }
            else {
                let e = msg["error"] as? [String: Any]
                cb(.failure(AgentError(e?["code"] as? String ?? "error", e?["message"] as? String ?? t("后台服务返回错误"))))
            }
            return
        }
        guard let ev = msg["event"] as? String else { return }
        emit(msg)
        switch ev {
        case "endpoints.changed", "autoRun", "settings.changed": refresh()
        case "pending": pending = decode(msg["pending"]) ?? pending
        default: break
        }
    }

    // MARK: requests

    func send(_ type: String, _ params: [String: Any] = [:], _ completion: ((Result<Any?, AgentError>) -> Void)? = nil) {
        guard connected, fd >= 0 else { completion?(.failure(AgentError("offline", connectionProblem ?? t("后台服务未运行")))); return }
        seq += 1
        let id = seq
        var req: [String: Any] = ["id": id, "type": type]
        if !params.isEmpty { req.merge(params) { a, _ in a } }
        guard let data = try? JSON.data(req) else { completion?(.failure(AgentError("encode", t("请求无法编码")))); return }
        pendingCalls[id] = completion ?? { _ in }
        let out = data + Data([0x0A])
        let c = fd
        io.async { _ = writeAll(c, out) }
    }

    func engine(_ method: String, _ params: [String: Any] = [:], _ completion: ((Result<Any?, AgentError>) -> Void)? = nil) {
        send("engine.\(method)", ["params": params], completion)
    }

    /// async/await wrappers used by the web UI bridge.
    func call(_ type: String, _ params: [String: Any] = [:]) async throws -> Any? {
        try await withCheckedThrowingContinuation { cont in
            send(type, params) { r in
                switch r {
                case .success(let v): cont.resume(returning: v)
                case .failure(let e): cont.resume(throwing: e)
                }
            }
        }
    }

    func engineCall(_ method: String, _ params: [String: Any] = [:]) async throws -> Any? {
        try await call("engine.\(method)", ["params": params])
    }

    /// Anything that wants raw agent events (the embedded web UI does).
    /// Sinks go away with their owner (a web view torn down and built again).
    func addEventSink(owner: AnyObject, _ sink: @escaping ([String: Any]) -> Void) {
        eventSinks.removeAll { $0.owner == nil }
        eventSinks.append(EventSink(owner: owner, fn: sink))
    }

    private func emit(_ event: [String: Any]) {
        eventSinks.removeAll { $0.owner == nil }
        for sink in eventSinks { sink.fn(event) }
    }

    func decode<T: Decodable>(_ value: Any?) -> T? {
        guard let v = value else { return nil }
        return try? JSON.decode(T.self, from: v)
    }

    // MARK: state

    /// Coalesces bursts (an agent event plus the web page's own status load) into one round.
    func refresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self = self else { return }
            self.refreshQueued = false
            self.refreshNow()
        }
    }

    private func refreshNow() {
        send("hello") { [weak self] r in
            Task { @MainActor in
                guard let self = self else { return }
                switch r {
                case .success(let v):
                    self.status = self.decode(v)
                    self.lastError = nil
                case .failure(let e):
                    self.lastError = e.message
                }
            }
        }
        refreshResident()
        engine("settings") { [weak self] r in
            Task { @MainActor in
                guard let self = self, case .success(let v) = r, let s: EngineSettings = self.decode(v) else { return }
                self.settings = s
                self.settingsLoaded = true
                self.applyLanguage(s.language)
            }
        }
        engine("pending") { [weak self] r in
            Task { @MainActor in
                guard let self = self, case .success(let v) = r else { return }
                self.pending = self.decode(v)
            }
        }
        refreshStorage()
        engine("lastRun") { [weak self] r in
            Task { @MainActor in
                guard let self = self, case .success(let v) = r,
                      let ms = (v as? [String: Any])?["at"] as? Double else { return }
                self.lastRunAt = Date(timeIntervalSince1970: ms / 1000)
            }
        }
    }

    /// Saves a settings patch (the engine deep-merges `endpoints`) and applies the result locally.
    func save(_ patch: [String: Any], note: String? = nil) {
        engine("saveSettings", ["patch": patch]) { [weak self] r in
            Task { @MainActor in
                guard let self = self else { return }
                switch r {
                case .success(let v):
                    if let s: EngineSettings = self.decode(v) {
                        self.settings = s
                        self.applyLanguage(s.language)
                    }
                    if let note = note { self.lastMessage = note }
                case .failure(let e):
                    self.lastError = t("保存设置失败：{msg}", ["msg": e.message])
                }
            }
        }
    }

    func setEndpoint(_ id: String, _ patch: [String: Any]) {
        save(["endpoints": [id: patch]])
    }

    // MARK: actions

    func syncNow() {
        guard busy == nil else { return }
        busy = t("正在扫描…")
        engine("scan") { [weak self] r in
            Task { @MainActor in
                guard let self = self else { return }
                switch r {
                case .failure(let e):
                    self.busy = nil
                    self.lastError = e.message
                case .success(let v):
                    guard let o = v as? [String: Any], let scanId = o["scanId"] as? String else {
                        self.busy = nil
                        self.lastError = t("扫描没有返回结果")
                        return
                    }
                    let items = (o["items"] as? [[String: Any]]) ?? []
                    if items.isEmpty {
                        self.busy = nil
                        self.lastMessage = t("两端已经一致，没有需要同步的项目")
                        self.refresh()
                        return
                    }
                    self.busy = t("正在同步 {n} 项…", ["n": items.count])
                    self.engine("run", ["scanId": scanId]) { rr in
                        Task { @MainActor in
                            self.busy = nil
                            switch rr {
                            case .success(let rv):
                                let res = rv as? [String: Any]
                                let remaining = res?["remaining"] as? Int ?? 0
                                self.lastMessage = remaining > 0 ? t("已同步，还有 {n} 项需要你确认", ["n": remaining]) : t("同步完成")
                            case .failure(let e):
                                self.lastError = e.message
                            }
                            self.refresh()
                        }
                    }
                }
            }
        }
    }

    func resetState(_ done: @escaping (String) -> Void) {
        send("state.reset") { r in
            Task { @MainActor in
                switch r {
                case .success: done(t("同步状态已重置，下次扫描会走首次同步流程"))
                case .failure(let e): done(t("重置失败：{msg}", ["msg": e.message]))
                }
            }
        }
    }

    func reveal(_ what: String) { send("reveal", ["what": what]) }

    // MARK: storage

    func refreshStorage() {
        send("storage.stats") { [weak self] r in
            Task { @MainActor in
                guard let self = self, case .success(let v) = r else { return }
                self.storage = self.decode(v)
            }
        }
    }

    /// dryRun first to show what would go; then again for real.
    func clean(_ what: String, dryRun: Bool, _ done: @escaping (CleanReport?) -> Void) {
        send("storage.clean", ["what": what, "dryRun": dryRun]) { [weak self] r in
            Task { @MainActor in
                guard let self = self else { return }
                switch r {
                case .success(let v):
                    let rep: CleanReport? = self.decode(v)
                    if !dryRun { self.refreshStorage() }
                    done(rep)
                case .failure(let e):
                    self.lastError = e.message
                    done(nil)
                }
            }
        }
    }

    func clearHistory(_ done: @escaping (Bool) -> Void) {
        engine("clearHistory") { r in
            Task { @MainActor in
                if case .failure(let e) = r { self.lastError = e.message; done(false) } else { done(true) }
            }
        }
    }

    func clearMessages() { lastMessage = nil; lastError = nil }

    func note(_ text: String) { lastMessage = text }

    /// Switches the interface language (settings value: system | zh | en).
    private func applyLanguage(_ setting: String?) {
        let before = I18n.lang
        if I18n.use(setting) != before { langToken += 1 }
    }

    // MARK: resident service

    func refreshResident() {
        Task.detached(priority: .utility) { [weak self] in
            let on = Installer.residentEnabled, approval = Installer.residentNeedsApproval
            await self?.setResidentState(on, approval)
        }
    }

    private func setResidentState(_ on: Bool, _ approval: Bool) {
        resident = on
        residentNeedsApproval = approval
    }

    func setResident(_ on: Bool) {
        guard !residentChanging else { return }
        residentChanging = true
        AgentSupervisor.shared.forgetOutage()
        lastError = nil
        connectionProblem = nil
        // registering, launchctl and stopping the temporary agent all block for a while
        Task.detached(priority: .userInitiated) { [weak self] in
            if on { AgentSupervisor.shared.stopTemporary() }
            let outcome: Result<String, Error>
            do { outcome = .success(try Installer.setResident(on)) } catch { outcome = .failure(error) }
            if !on { AgentSupervisor.shared.ensureRunning() }
            let enabled = Installer.residentEnabled, approval = Installer.residentNeedsApproval
            await self?.residentChanged(outcome, enabled, approval)
        }
    }

    private func residentChanged(_ outcome: Result<String, Error>, _ enabled: Bool, _ approval: Bool) {
        residentChanging = false
        setResidentState(enabled, approval)
        switch outcome {
        case .success(let line): lastMessage = line
        case .failure(let e as AgentError): lastError = e.message
        case .failure(let e): lastError = e.localizedDescription
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refresh() }
    }

    /// Restarts whichever agent is running, so it picks up a changed Safari path.
    func restartAgent() {
        AgentSupervisor.shared.forgetOutage()
        failures = 0
        lastError = nil
        connectionProblem = nil
        dropped()
        connect() // also when there was no connection to drop: this is the way to retry
        Task.detached(priority: .utility) {
            // the new agent's socket wakes connect(); launchctl may take a moment
            if Installer.residentEnabled { Installer.kickstartResident() }
            else { AgentSupervisor.shared.restartTemporary() }
        }
    }
}
