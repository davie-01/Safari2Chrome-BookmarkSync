import Foundation
import SafariBookmarks

/// Long-running agent. Owns Safari file access (Full Disk Access is granted to
/// BookmarkSync.app), the sync state, and the sync engine (JavaScriptCore). Browser
/// extensions connect through the native messaging host and act as endpoints: the agent
/// sends them RPCs to read/write their bookmarks.
///
/// Wire format: newline-delimited JSON over a user-only Unix socket.
///   request   {"id": 1, "type": "engine.scan", "params": {...}}  ->  {"id": 1, "ok": true, "result": ...}
///   event     {"event": "bookmarks.changed", ...}                  (either direction, no reply)
///   agent RPC {"rpc": 7, "method": "read", "params": {...}}       ->  {"rpcReply": 7, "ok": true, "result": ...}
///   host      {"type": "host.hello", "browserPath": "..."}         (sent once by the native host)
public final class Agent {
    final class Conn {
        let fd: Int32
        let writeLock = NSLock()
        let lock = NSLock()
        var endpoint: [String: Any]?
        var browserPath: String?
        var pending: [Int: EngineHost.Reply] = [:]
        var connectedAt = Date()
        init(fd: Int32) { self.fd = fd }
    }

    let safari: SafariStore
    let state: StateStore
    let socketPath: String
    let work = DispatchQueue(label: "bmsync.agent.work")
    let requests = DispatchQueue(label: "bmsync.agent.requests", attributes: .concurrent)
    private var conns: [Int32: Conn] = [:]
    private let connsLock = NSLock()
    private var rpcSeq = 0
    private var timer: DispatchSourceTimer?
    private var lastStat: (mtime: TimeInterval, size: Int)?
    private var lastRunning: Bool?
    private var engine: EngineHost?
    private var autoTimer: DispatchWorkItem?
    private var periodic: DispatchSourceTimer?
    private var kv: [String: Any] = [:]

    public init(safari: SafariStore? = nil, state: StateStore = StateStore(), socketPath: String = Paths.socket.path) {
        self.safari = safari ?? SafariStore(url: Agent.configuredSafariURL())
        self.state = state
        self.socketPath = socketPath
    }

    /// settings.safariPath (a Bookmarks.plist or a folder containing one) or the default.
    static func configuredSafariURL() -> URL {
        guard let s = Agent.readSettings()?["safariPath"] as? String, !s.isEmpty else { return Paths.safariBookmarks }
        var u = URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
            u = u.appendingPathComponent("Bookmarks.plist")
        }
        return u
    }

    static var settingsURL: URL { Paths.support.appendingPathComponent("settings.json") }
    static var kvURL: URL { Paths.support.appendingPathComponent("ui-state.json") }

    static func readSettings() -> [String: Any]? {
        guard let d = try? Data(contentsOf: settingsURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    public func run() throws -> Never {
        signal(SIGPIPE, SIG_IGN)
        try Paths.ensureDir(Paths.support)
        try Agent.acquireSingleInstanceLock()
        let fd = try listen()
        if let d = try? Data(contentsOf: Agent.kvURL), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { kv = o }
        do {
            engine = try EngineHost(script: try EngineHost.bundledScript(), native: { [weak self] m, p, r in self?.nativeCall(m, p, r) })
        } catch {
            Log.error("engine unavailable: \(error)")
        }
        Log.info("agent \(AppInfo.version) listening on \(socketPath); safari=\(safari.url.path) access=\(safari.access().rawValue) engine=\(engine != nil)")
        startWatcher()
        startPeriodic()
        if CommandLine.arguments.contains("--exit-with-parent") { startParentWatch() }
        Installer.refreshNativeHostManifests()
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 { if errno == EINTR { continue }; Log.error("accept errno=\(errno)"); sleep(1); continue }
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            guard peerIsSameUser(c) else { Log.warn("rejected peer with different uid"); close(c); continue }
            let conn = Conn(fd: c)
            connsLock.lock(); conns[c] = conn; connsLock.unlock()
            Thread.detachNewThread { [weak self] in self?.serve(conn) }
        }
    }

    /// Only one agent may own the socket and the state; a second one exits instead of
    /// stealing the socket (the app starts a temporary agent when the resident one is off).
    private static var lockFD: Int32 = -1
    static func acquireSingleInstanceLock() throws {
        let path = Paths.support.appendingPathComponent("agent.lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw AgentError("lock", "cannot open \(path): errno=\(errno)") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw AgentError("alreadyRunning", "another BookmarkSync agent is already running")
        }
        lockFD = fd
    }

    /// Temporary agents started by the app must not outlive it, even if the app is killed
    /// without a chance to clean up: once our parent is gone, getppid() is 1.
    func startParentWatch() {
        Thread.detachNewThread {
            while true {
                Thread.sleep(forTimeInterval: 2)
                if getppid() == 1 {
                    Log.info("parent app exited; temporary agent stopping")
                    exit(0)
                }
            }
        }
    }

    func listen() throws -> Int32 {
        unlink(socketPath)
        var addr = try unixAddress(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentError("socket", "socket() errno=\(errno)") }
        let old = umask(0o077)
        defer { umask(old) }
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard r == 0 else { throw AgentError("socket", "bind errno=\(errno)") }
        chmod(socketPath, 0o600)
        guard Darwin.listen(fd, 16) == 0 else { throw AgentError("socket", "listen errno=\(errno)") }
        return fd
    }

    func peerIsSameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }

    // MARK: connection loop

    func serve(_ conn: Conn) {
        let reader = LineReader(fd: conn.fd)
        while let line = reader.next() {
            if line.isEmpty { continue }
            guard let msg = try? JSON.object(line) else { continue }
            if let rid = msg["rpcReply"] as? Int {
                conn.lock.lock(); let cb = conn.pending.removeValue(forKey: rid); conn.lock.unlock()
                if msg["ok"] as? Bool == true { cb?(.success(msg["result"])) }
                else {
                    let e = msg["error"] as? [String: Any]
                    cb?(.failure(AgentError(e?["code"] as? String ?? "rpcError", e?["message"] as? String ?? "endpoint error")))
                }
                continue
            }
            if let ev = msg["event"] as? String { handleEvent(conn, ev, msg); continue }
            if msg["type"] as? String == "host.hello" {
                conn.browserPath = msg["browserPath"] as? String
                continue
            }
            let reqId = msg["id"] ?? NSNull()
            requests.async {
                self.handleAsync(conn, msg) { result in
                    switch result {
                    case .success(let v): self.send(conn, ["id": reqId, "ok": true, "result": v ?? NSNull()])
                    case .failure(let e): self.send(conn, ["id": reqId, "ok": false, "error": ["code": e.code, "message": e.message]])
                    }
                }
            }
        }
        // disconnected
        connsLock.lock(); conns.removeValue(forKey: conn.fd); connsLock.unlock()
        conn.lock.lock(); let pend = conn.pending; conn.pending = [:]; conn.lock.unlock()
        for (_, cb) in pend { cb(.failure(AgentError("endpointGone", "browser disconnected"))) }
        close(conn.fd)
        if let id = conn.endpoint?["id"] as? String {
            Log.info("endpoint offline: \(id)")
            broadcast(["event": "endpoints.changed"])
        }
    }

    func send(_ conn: Conn, _ obj: [String: Any]) {
        guard var data = try? JSON.data(obj) else { return }
        data.append(0x0A)
        conn.writeLock.lock()
        _ = writeAll(conn.fd, data)
        conn.writeLock.unlock()
    }

    func broadcast(_ obj: [String: Any]) {
        connsLock.lock(); let all = Array(conns.values); connsLock.unlock()
        for c in all where c.endpoint != nil || c.browserPath == nil { send(c, obj) }
    }

    func rpc(_ conn: Conn, _ method: String, _ params: Any?, timeout: TimeInterval = 90, _ reply: @escaping EngineHost.Reply) {
        conn.lock.lock()
        rpcSeq += 1
        let id = rpcSeq
        var done = false
        conn.pending[id] = { r in
            conn.lock.lock(); let first = !done; done = true; conn.lock.unlock()
            if first { reply(r) }
        }
        conn.lock.unlock()
        send(conn, ["rpc": id, "method": method, "params": params ?? NSNull()])
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            conn.lock.lock(); let cb = conn.pending.removeValue(forKey: id); conn.lock.unlock()
            cb?(.failure(AgentError("timeout", "browser did not answer \(method)")))
        }
    }

    // MARK: events from browsers

    func handleEvent(_ conn: Conn, _ ev: String, _ msg: [String: Any]) {
        switch ev {
        case "bookmarks.changed": scheduleAuto("\(conn.endpoint?["id"] as? String ?? "?"):changed")
        default: break
        }
    }

    // MARK: endpoints

    static let browserNames: [String: String] = [
        "chrome": "Chrome", "chrome-beta": "Chrome Beta", "chrome-dev": "Chrome Dev", "chrome-canary": "Chrome Canary",
        "chromium": "Chromium", "edge": "Edge", "edge-beta": "Edge Beta", "edge-dev": "Edge Dev", "edge-canary": "Edge Canary",
        "brave": "Brave", "vivaldi": "Vivaldi", "arc": "Arc", "opera": "Opera", "yandex": "Yandex",
    ]

    static func browserKey(fromPath p: String?) -> String? {
        guard let p = p else { return nil }
        let table: [(String, String)] = [
            ("Google Chrome Canary.app", "chrome-canary"), ("Google Chrome Dev.app", "chrome-dev"), ("Google Chrome Beta.app", "chrome-beta"),
            ("Google Chrome.app", "chrome"), ("Microsoft Edge Canary.app", "edge-canary"), ("Microsoft Edge Dev.app", "edge-dev"),
            ("Microsoft Edge Beta.app", "edge-beta"), ("Microsoft Edge.app", "edge"), ("Brave Browser", "brave"), ("Vivaldi.app", "vivaldi"),
            ("Arc.app", "arc"), ("Opera.app", "opera"), ("Yandex.app", "yandex"), ("Chromium.app", "chromium"),
        ]
        return table.first { p.contains($0.0) }?.1
    }

    func chromiumConns() -> [Conn] {
        connsLock.lock(); defer { connsLock.unlock() }
        return conns.values.filter { $0.endpoint != nil }.sorted { $0.connectedAt < $1.connectedAt }
    }

    func conn(forEndpoint id: String) -> Conn? {
        chromiumConns().last { ($0.endpoint?["id"] as? String) == id }
    }

    func endpointList() -> [[String: Any]] {
        let settings = Agent.readSettings() ?? [:]
        let prefs = settings["endpoints"] as? [String: Any] ?? [:]
        let nameOverride = { (id: String) in (prefs[id] as? [String: Any])?["name"] as? String }
        var list: [[String: Any]] = [[
            "id": "safari", "kind": "safari", "browser": "safari",
            "name": nameOverride("safari") ?? "Safari",
            "online": safari.access() == .ok,
        ]]
        var seen: [String: Int] = [:]
        var byId: [String: [String: Any]] = [:]
        for c in chromiumConns() {
            guard let ep = c.endpoint, let id = ep["id"] as? String else { continue }
            let browser = Agent.browserKey(fromPath: c.browserPath) ?? (ep["browser"] as? String) ?? "chromium"
            seen[browser, default: 0] += 1
            let base = Agent.browserNames[browser] ?? browser.capitalized
            let n = seen[browser]!
            byId[id] = [
                "id": id, "kind": "chromium", "browser": browser,
                "name": nameOverride(id) ?? (ep["profileLabel"] as? String).map { "\(base) · \($0)" } ?? (n > 1 ? "\(base) \(n)" : base),
                "online": true,
            ]
        }
        list.append(contentsOf: byId.values.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") })
        return list
    }

    // MARK: requests

    func handleAsync(_ conn: Conn, _ req: [String: Any], _ reply: @escaping EngineHost.Reply) {
        let type = req["type"] as? String ?? ""
        if type.hasPrefix("engine.") {
            guard let engine = engine else { reply(.failure(AgentError("engineUnavailable", "sync engine failed to load; see agent.log"))); return }
            let method = String(type.dropFirst("engine.".count))
            engine.handle(method, req["params"]) { [weak self] r in
                if method == "run" || method == "autoRun" { self?.afterRun() }
                if method == "saveSettings" { self?.settingsChanged() }
                reply(r)
            }
            return
        }
        if type == "endpoint.hello" {
            guard let ep = req["endpoint"] as? [String: Any], let id = ep["id"] as? String, !id.isEmpty else {
                reply(.failure(AgentError("badRequest", "missing endpoint id"))); return
            }
            // one live connection per endpoint id
            for other in chromiumConns() where other !== conn && (other.endpoint?["id"] as? String) == id { other.endpoint = nil }
            conn.endpoint = ep
            Log.info("endpoint online: \(id) browser=\(Agent.browserKey(fromPath: conn.browserPath) ?? ep["browser"] as? String ?? "?")")
            broadcast(["event": "endpoints.changed"])
            scheduleAuto("\(id):online")
            let me = endpointList().first { ($0["id"] as? String) == id }
            reply(.success(["endpoint": me ?? [:], "version": AppInfo.version]))
            return
        }
        // The app has no chrome.bookmarks of its own: browser-side work (e.g. restoring the
        // order from an HTML export) is forwarded to a connected browser endpoint.
        if type == "endpoint.rpc" {
            let wanted = req["endpointId"] as? String
            let target = wanted.flatMap { self.conn(forEndpoint: $0) }
                ?? chromiumConns().first { $0.endpoint != nil }
            guard let target = target else {
                reply(.failure(AgentError("noEndpoint", "没有在线的浏览器端；请打开装了 BookmarkSync 扩展的浏览器")))
                return
            }
            guard let method = req["method"] as? String else {
                reply(.failure(AgentError("badRequest", "missing method"))); return
            }
            rpc(target, method, req["params"], timeout: 180, reply)
            return
        }
        work.async {
            do { reply(.success(try self.handle(req))) }
            catch let e as AgentError { reply(.failure(e)) }
            catch { reply(.failure(AgentError("internal", "\(error)"))) }
        }
    }

    /// Simple synchronous requests (always on `work`).
    func handle(_ req: [String: Any]) throws -> Any {
        let type = req["type"] as? String ?? ""
        switch type {
        case "ping":
            return ["pong": true]
        case "hello", "status":
            let st = safari.stat()
            return [
                "version": AppInfo.version,
                "agentPid": Int(getpid()),
                "executable": Installer.executablePath,
                "safariPath": safari.url.path,
                "safariAccess": safari.access().rawValue,
                "safariRunning": SafariStore.safariRunning(),
                "safariMtime": st?.mtime ?? 0,
                "supportDir": Paths.support.path,
                "engine": engine != nil,
                "endpoints": endpointList(),
            ] as [String: Any]
        case "state.reset":
            try state.reset()
            kvSet("pending", nil)
            return ["revision": 0]
        case "storage.stats":
            return Cleanup.stats()
        case "storage.clean":
            let st = Agent.readSettings() ?? [:]
            let p = (req["params"] as? [String: Any]) ?? req
            let dry = p["dryRun"] as? Bool ?? false
            let report = Cleanup.clean(
                what: p["what"] as? String ?? "all",
                backupDays: p["backupDays"] as? Int ?? st["backupDays"] as? Int ?? Cleanup.defaultBackupDays,
                logDays: p["logDays"] as? Int ?? st["logDays"] as? Int ?? Cleanup.defaultLogDays,
                keepMinBackups: st["backupKeepMin"] as? Int ?? Cleanup.defaultKeepMinBackups,
                dryRun: dry)
            if !dry { Log.info("cleanup (manual): \(Cleanup.describe(report))") }
            return report
        case "uninstall.plan":
            return Uninstall.plan().map { ["path": $0.path, "label": $0.label, "bytes": $0.bytes, "dir": $0.isDirectory] }
        case "uninstall.run":
            let r = Uninstall.run(trashApp: false)
            return ["removed": r.removed, "failed": r.failed.map { ["path": $0.path, "error": $0.error] },
                    "bytes": r.bytes, "residue": r.residue]
        case "backups.list":
            let names = (try? FileManager.default.contentsOfDirectory(atPath: Paths.backups.path)) ?? []
            return names.filter { $0.hasPrefix("Bookmarks-") }.sorted().reversed().map { n -> [String: Any] in
                let p = Paths.backups.appendingPathComponent(n).path
                let size = ((try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? Int) ?? 0
                return ["name": n, "path": p, "size": size]
            }
        case "log":
            let lvl = (req["level"] as? String ?? "info").uppercased()
            let msg = (req["message"] as? String ?? "").prefix(2000)
            Log.shared.write("EXT-\(lvl)", String(msg))
            return ["ok": true]
        case "reveal":
            let what = req["what"] as? String ?? "backups"
            // "backup" + a file name selects that backup in Finder (history detail view)
            if what == "backup", let name = req["name"] as? String, !name.contains("/") {
                let file = Paths.backups.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: file.path) {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                    p.arguments = ["-R", file.path]
                    try? p.run()
                    return ["ok": true]
                }
            }
            let url = what == "logs" ? Paths.logs : Paths.backups
            try? Paths.ensureDir(url)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = [url.path]
            try? p.run()
            return ["ok": true]
        default:
            throw AgentError("unknownType", "unknown request type '\(type)'")
        }
    }

    // MARK: natives for the engine

    func nativeCall(_ method: String, _ params: Any?, _ reply: @escaping EngineHost.Reply) {
        let p = params as? [String: Any] ?? [:]
        func onWork(_ body: @escaping () throws -> Any?) {
            work.async {
                do { reply(.success(try body())) }
                catch let e as AgentError { reply(.failure(e)) }
                catch { reply(.failure(AgentError("internal", "\(error)"))) }
            }
        }
        switch method {
        case "store.load":
            onWork { let (s, rev) = try self.state.load(); return ["state": (s as Any?) ?? NSNull(), "revision": rev] }
        case "store.save":
            onWork {
                guard let s = p["state"] else { throw AgentError("badRequest", "missing state") }
                return ["revision": try self.state.save(s, expectedRevision: p["expectedRevision"] as? Int ?? -1)]
            }
        case "settings.load":
            onWork { Agent.readSettings() }
        case "settings.save":
            onWork {
                guard let v = p["settings"] as? [String: Any] else { throw AgentError("badRequest", "missing settings") }
                try Paths.ensureDir(Paths.support)
                try JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys]).write(to: Agent.settingsURL, options: [.atomic])
                return ["ok": true]
            }
        case "kv.get":
            onWork { self.kv[p["key"] as? String ?? ""] }
        case "kv.set":
            onWork { self.kvSet(p["key"] as? String ?? "", p["value"]); return ["ok": true] }
        case "endpoints.list":
            onWork { self.endpointList() }
        case "endpoint.read":
            let id = p["id"] as? String ?? ""
            if id == "safari" {
                onWork {
                    let r = try self.safari.readNormalized()
                    return ["tree": try JSON.value(r.tree), "fingerprint": r.fingerprint]
                }
            } else if let c = conn(forEndpoint: id) {
                rpc(c, "read", p["prefs"], reply)
            } else {
                reply(.failure(AgentError("endpointOffline", "\(id) is not connected")))
            }
        case "endpoint.apply":
            let id = p["id"] as? String ?? ""
            let opts = p["opts"] as? [String: Any] ?? [:]
            if id == "safari" {
                onWork {
                    let ops = try JSON.decode([SafariOp].self, from: p["ops"] ?? [])
                    var o = SafariStore.ApplyOptions()
                    o.allowWhileSafariRunning = opts["allowWhileSafariRunning"] as? Bool ?? false
                    do {
                        let r = try self.safari.apply(ops, options: o)
                        self.lastStat = self.safari.stat() // our own write is not an external change
                        return ["applied": r.applied, "backup": (r.backup as Any?) ?? NSNull()]
                    } catch let e as AgentError where e.code == "safariRunning" {
                        return ["deferred": true, "reason": e.message]
                    }
                }
            } else if let c = conn(forEndpoint: id) {
                rpc(c, "apply", ["ops": p["ops"] ?? [], "prefs": opts], timeout: 300, reply)
            } else {
                reply(.failure(AgentError("endpointOffline", "\(id) is not connected")))
            }
        default:
            reply(.failure(AgentError("unknownNative", method)))
        }
    }

    func kvSet(_ key: String, _ value: Any?) {
        if let v = value, !(v is NSNull) { kv[key] = v } else { kv.removeValue(forKey: key) }
        if let d = try? JSONSerialization.data(withJSONObject: kv, options: [.fragmentsAllowed]) {
            try? d.write(to: Agent.kvURL, options: [.atomic])
        }
    }

    // MARK: resident mode

    func autoSettings() -> (on: Bool, delay: Double) {
        let s = Agent.readSettings() ?? [:]
        return (s["autoSync"] as? Bool ?? false, max(2, s["autoDelay"] as? Double ?? 5))
    }

    func scheduleAuto(_ reason: String) {
        broadcast(["event": "changed", "reason": reason])
        let (on, delay) = autoSettings()
        guard on, engine != nil else { return }
        work.async {
            self.autoTimer?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.runAuto(reason) }
            self.autoTimer = item
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    func runAuto(_ reason: String) {
        guard let engine = engine else { return }
        engine.handle("autoRun", nil) { [weak self] r in
            switch r {
            case .success(let v):
                if let d = v as? [String: Any], d["skipped"] == nil { Log.info("auto sync (\(reason)): ok=\(d["ok"] ?? "?") remaining=\(d["remaining"] ?? "?")") }
                self?.broadcast(["event": "autoRun", "result": v ?? NSNull()])
            case .failure(let e):
                if e.code != "busy" { Log.warn("auto sync failed (\(reason)): \(e.code) \(e.message)") }
                if e.code == "changedSinceScan" || e.code == "busy" { self?.scheduleAuto("retry") }
            }
            self?.afterRun()
        }
    }

    func afterRun() {
        broadcast(["event": "pending", "pending": kv["pending"] ?? NSNull()])
    }

    func settingsChanged() {
        scheduleAuto("settings")
    }

    func startPeriodic() {
        let t = DispatchSource.makeTimerSource(queue: work)
        t.schedule(deadline: .now() + 30, repeating: 15 * 60, leeway: .seconds(30))
        t.setEventHandler { [weak self] in
            self?.scheduleAuto("periodic")
            Installer.refreshNativeHostManifests()
            self?.autoCleanIfDue()
            self?.selfCleanIfAppGone()
        }
        t.resume()
        periodic = t
    }

    /// Once a day: drop old backups and logs by the retention settings.
    func autoCleanIfDue() {
        let st = Agent.readSettings() ?? [:]
        guard st["autoClean"] as? Bool != false else { return }
        let last = kv["lastCleanAt"] as? Double ?? 0
        let now = Date().timeIntervalSince1970 * 1000
        guard now - last > 20 * 3600 * 1000 else { return }
        let report = Cleanup.clean(
            backupDays: st["backupDays"] as? Int ?? Cleanup.defaultBackupDays,
            logDays: st["logDays"] as? Int ?? Cleanup.defaultLogDays,
            keepMinBackups: st["backupKeepMin"] as? Int ?? Cleanup.defaultKeepMinBackups)
        kvSet("lastCleanAt", now)
        Log.info("cleanup (daily): \(Cleanup.describe(report))")
    }

    /// The app was dragged to the Trash: clean up after ourselves and stop. An upgrade
    /// replaces the bundle in seconds, so only act after two checks 15 minutes apart.
    private var appGoneStrikes = 0
    func selfCleanIfAppGone() {
        guard Uninstall.appBundleMissing() else { appGoneStrikes = 0; return }
        appGoneStrikes += 1
        guard appGoneStrikes >= 2 else {
            Log.warn("app bundle is missing; will clean up if it is still gone at the next check")
            return
        }
        Log.info("app bundle is gone; removing what is left and stopping")
        Uninstall.run(trashApp: false)
        exit(0)
    }

    // MARK: Safari watcher

    func startWatcher() {
        let t = DispatchSource.makeTimerSource(queue: work)
        t.schedule(deadline: .now() + 1, repeating: 2.0, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func tick() {
        let running = SafariStore.safariRunning()
        if running != lastRunning {
            if lastRunning != nil {
                broadcast(["event": "safari.running", "running": running])
                if !running { scheduleAuto("safari.quit") }
            }
            lastRunning = running
        }
        let st = safari.stat()
        let changed: Bool
        switch (st, lastStat) {
        case let (a?, b?): changed = a.mtime != b.mtime || a.size != b.size
        case (nil, nil): changed = false
        default: changed = true
        }
        if changed {
            if lastStat != nil || st == nil {
                broadcast(["event": "safari.changed", "mtime": st?.mtime ?? 0])
                scheduleAuto("safari.changed")
            }
            lastStat = st
        }
    }
}
