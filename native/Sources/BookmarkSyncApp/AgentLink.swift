import Foundation
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
    @Published private(set) var busy: String?
    @Published private(set) var lastMessage: String?
    @Published private(set) var resident = Installer.residentEnabled
    @Published var tab: AppTab = .sync
    @Published private(set) var lastRunAt: Date?
    @Published private(set) var storage: StorageStats?
    /// Bumped when the interface language changes, so the embedded web UI reloads.
    @Published private(set) var langToken = 0

    private var fd: Int32 = -1
    private var seq = 0
    private var pendingCalls: [Int: (Result<Any?, AgentError>) -> Void] = [:]
    /// Writes only; the read loop gets a thread of its own so it cannot block them.
    private let io = DispatchQueue(label: "bmsync.app.link.write")
    private var reconnectTimer: Timer?
    private var eventSinks: [([String: Any]) -> Void] = []

    var endpoints: [EndpointInfo] { status?.endpoints ?? [] }

    // MARK: connection

    func start() {
        connect()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if !self.connected { self.connect() }
            }
        }
    }

    func connect() {
        guard !connected else { return }
        AgentSupervisor.shared.ensureRunning()
        guard let c = connectUnix(Paths.socket.path) else { return }
        fd = c
        connected = true
        lastError = nil
        Thread.detachNewThread { [weak self] in
            let reader = LineReader(fd: c)
            while let line = reader.next() {
                guard let msg = try? JSON.object(line) else { continue }
                Task { @MainActor in self?.receive(msg) }
            }
            Task { @MainActor in self?.dropped() }
        }
        refresh()
    }

    private func dropped() {
        guard connected || fd >= 0 else { return }
        if fd >= 0 { close(fd); fd = -1 }
        connected = false
        status = nil
        for sink in eventSinks { sink(["event": "agent.disconnected"]) }
        for (_, cb) in pendingCalls { cb(.failure(AgentError("disconnected", t("与后台服务的连接断开")))) }
        pendingCalls = [:]
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
        for sink in eventSinks { sink(msg) }
        switch ev {
        case "endpoints.changed", "autoRun", "settings.changed": refresh()
        case "pending": pending = decode(msg["pending"]) ?? pending
        default: break
        }
    }

    // MARK: requests

    func send(_ type: String, _ params: [String: Any] = [:], _ completion: ((Result<Any?, AgentError>) -> Void)? = nil) {
        guard connected, fd >= 0 else { completion?(.failure(AgentError("offline", t("后台服务未运行")))); return }
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
    func addEventSink(_ sink: @escaping ([String: Any]) -> Void) { eventSinks.append(sink) }

    func decode<T: Decodable>(_ value: Any?) -> T? {
        guard let v = value else { return nil }
        return try? JSON.decode(T.self, from: v)
    }

    // MARK: state

    func refresh() {
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
                self.resident = Installer.residentEnabled
            }
        }
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

    func setResident(_ on: Bool) {
        do {
            if on { AgentSupervisor.shared.stopTemporary() }
            let line = try Installer.setResident(on)
            resident = Installer.residentEnabled
            lastMessage = line
            if !on { AgentSupervisor.shared.ensureRunning() }
        } catch let e as AgentError {
            lastError = e.message
            resident = Installer.residentEnabled
        } catch {
            lastError = error.localizedDescription
            resident = Installer.residentEnabled
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refresh() }
    }

    /// Restarts whichever agent is running, so it picks up a changed Safari path.
    func restartAgent() {
        if Installer.residentEnabled {
            Installer.kickstartResident()
        } else {
            AgentSupervisor.shared.restartTemporary()
        }
        dropped()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.connect() }
    }
}
