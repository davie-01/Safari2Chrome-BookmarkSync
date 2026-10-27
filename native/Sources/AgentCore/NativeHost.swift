import Foundation

/// Chrome native messaging host: launched by Chrome, speaks 4-byte length-prefixed JSON on
/// stdin/stdout and relays to the agent's Unix socket. It never touches Safari files itself
/// (a Chrome-spawned process is attributed to Chrome by TCC and has no Full Disk Access).
///
/// Chrome caps host->extension messages at 1 MB, so large agent replies are split into
/// {"chunk": {"cid", "seq", "total", "b64"}} frames which the extension reassembles.
public enum NativeHost {
    public static let maxFrame = 1024 * 1024
    public static let chunkPayload = 600 * 1024 // raw bytes per chunk before base64

    public static func run(origin: String) -> Never {
        signal(SIGPIPE, SIG_IGN)
        Log.shared.open(name: "native-host")
        Log.info("host start origin=\(origin)")
        let out = FrameWriter(fd: STDOUT_FILENO)

        let browserPath = parentExecutable()
        Log.info("host parent=\(browserPath ?? "?")")
        // tells the agent which browser we belong to before anything is relayed
        let hello = (try? JSON.data(["type": "host.hello", "browserPath": browserPath ?? "", "origin": origin])) ?? Data()
        let up = AgentUpstream(socketPath: Paths.socket.path, out: out, hello: hello)
        up.start()

        while true {
            guard let lenData = readExactly(STDIN_FILENO, 4) else { break }
            let len = lenData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
            guard len > 0, len < 64 * 1024 * 1024, let msg = readExactly(STDIN_FILENO, Int(len)) else { break }
            guard let s = up.current() else {
                replyAgentUnavailable(msg, out: out)
                continue
            }
            var line = msg
            line.append(0x0A)
            if !writeAll(s, line) {
                up.drop(s)
                replyAgentUnavailable(msg, out: out)
            }
        }
        Log.info("host stdin closed, exiting")
        exit(0)
    }

    /// Path of the process that launched us (the browser), used to tell Chrome from Edge etc.
    static func parentExecutable() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "comm=", "-p", String(getppid())]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let s = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty ?? true) ? nil : s
    }

    static func kickstartAgent() {
        for label in [AppInfo.embeddedAgentLabel, AppInfo.agentLabel] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["kickstart", "gui/\(getuid())/\(label)"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
    }

    static func replyAgentUnavailable(_ msg: Data, out: FrameWriter) {
        let id = (try? JSON.object(msg))?["id"] ?? NSNull()
        let resp: [String: Any] = [
            "id": id, "ok": false,
            "error": ["code": "agentUnavailable", "message": "BookmarkSync 后台服务未运行。请在终端执行：BookmarkSync.app/Contents/MacOS/bmsync install"],
        ]
        if let d = try? JSON.data(resp) { out.send(d) }
    }

}

/// The host's connection to the agent. It outlives the agent: when the agent goes, the host
/// keeps the browser's port, waits for the agent's socket to appear again (it binds a fresh
/// one on every start) and reconnects by itself, then tells the extension
/// ("agent.available") so it announces itself again. Nothing polls in between.
final class AgentUpstream {
    let socketPath: String
    private let out: FrameWriter
    private let hello: Data
    private let kickstart: () -> Void
    private let lock = NSLock()
    private var fd: Int32?
    private var lastKickstart: Date?
    private var watcher: FileWatcher?
    private let queue = DispatchQueue(label: "bmsync.host.upstream")
    /// Follow-up attempts of one reconnect, in progress (only touched on `queue`).
    private var retrying = false
    /// The socket file appears at bind(), a moment before the agent listens on it: a refused
    /// connect right after the event is retried a few times (about 3 s in all), then left
    /// to the next event.
    static let settleWaits: [Double] = [0.05, 0.1, 0.2, 0.4, 0.8, 1.6]

    init(socketPath: String, out: FrameWriter, hello: Data, kickstart: @escaping () -> Void = NativeHost.kickstartAgent) {
        self.socketPath = socketPath
        self.out = out
        self.hello = hello
        self.kickstart = kickstart
    }

    func start() {
        let w = FileWatcher(url: URL(fileURLWithPath: socketPath), queue: queue) { [weak self] in self?.socketMayBeBack() }
        if !w.start() { Log.warn("cannot watch \(socketPath); reconnecting only when the browser sends something") }
        watcher = w
        if current() == nil { Log.warn("agent not reachable at \(socketPath)") }
    }

    /// The live connection, connecting if there is none. When the agent is down this nudges
    /// launchd at most once a minute and returns nil at once: the reply is "unavailable", and
    /// the socket appearing later reconnects and announces it.
    func current() -> Int32? {
        lock.lock(); defer { lock.unlock() }
        if let fd = fd { return fd }
        if let s = connectUnix(socketPath) { attachLocked(s); return s }
        if lastKickstart.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
            lastKickstart = Date()
            DispatchQueue.global().async(execute: kickstart)
        }
        return nil
    }

    /// A write failed: let the reader wind the connection down (it reports and reconnects).
    func drop(_ s: Int32) {
        lock.lock(); defer { lock.unlock() }
        if fd == s { shutdown(s, SHUT_RDWR) }
    }

    /// On `queue`: the socket may be back (folder event, or our reader saw the old one end).
    private func socketMayBeBack() {
        guard !retrying else { return }
        retrying = true
        attempt(0)
    }

    private func attempt(_ n: Int) {
        switch reconnect() {
        case .connected, .notNeeded: retrying = false
        case .refused:
            guard n < AgentUpstream.settleWaits.count else { retrying = false; return }
            queue.asyncAfter(deadline: .now() + AgentUpstream.settleWaits[n]) { [weak self] in self?.attempt(n + 1) }
        }
    }

    private enum Reconnect { case connected, notNeeded, refused }

    private func reconnect() -> Reconnect {
        lock.lock()
        if fd != nil { lock.unlock(); return .notNeeded }
        guard let s = connectUnix(socketPath) else { lock.unlock(); return .refused }
        attachLocked(s)
        lock.unlock()
        Log.info("agent reachable again")
        if let d = try? JSON.data(["event": "agent.available"]) { out.send(d) }
        return .connected
    }

    private func attachLocked(_ s: Int32) {
        _ = writeAll(s, hello + Data([0x0A]))
        fd = s
        Thread.detachNewThread { [weak self] in
            let reader = LineReader(fd: s)
            while let line = reader.next() {
                if line.isEmpty { continue }
                self?.out.sendChunked(line)
            }
            guard let self = self else { close(s); return }
            self.lock.lock()
            if self.fd == s { self.fd = nil }
            self.lock.unlock()
            close(s)
            Log.warn("agent connection closed")
            // the extension fails what it was waiting for and waits for "agent.available"
            if let d = try? JSON.data(["event": "agent.disconnected"]) { self.out.send(d) }
            // a restarting agent may have bound its new socket before we saw the old one end
            self.queue.async { self.socketMayBeBack() }
        }
    }
}

public final class FrameWriter {
    let fd: Int32
    let lock = NSLock()
    public init(fd: Int32) { self.fd = fd }

    public func send(_ payload: Data) {
        var len = UInt32(payload.count).littleEndian
        var frame = Data(bytes: &len, count: 4)
        frame.append(payload)
        lock.lock(); defer { lock.unlock() }
        _ = writeAll(fd, frame)
    }

    /// Sends each chunk as soon as it is encoded: only one chunk is held besides the payload.
    public func sendChunked(_ payload: Data) {
        FrameWriter.forEachFrame(of: payload) { send($0) }
    }

    /// Splits a message that would exceed Chrome's 1 MB limit into base64 chunks.
    public static func frames(for payload: Data, limit: Int = NativeHost.maxFrame - 1024, chunk: Int = NativeHost.chunkPayload) -> [Data] {
        var out: [Data] = []
        forEachFrame(of: payload, limit: limit, chunk: chunk) { out.append($0) }
        return out
    }

    static func forEachFrame(of payload: Data, limit: Int = NativeHost.maxFrame - 1024, chunk: Int = NativeHost.chunkPayload, _ body: (Data) -> Void) {
        if payload.count <= limit { body(payload); return }
        let cid = UUID().uuidString
        let total = (payload.count + chunk - 1) / chunk
        for seq in 0..<total {
            let start = payload.startIndex + seq * chunk
            let end = min(payload.endIndex, start + chunk)
            let b64 = payload[start..<end].base64EncodedString()
            let obj: [String: Any] = ["chunk": ["cid": cid, "seq": seq, "total": total, "b64": b64]]
            if let d = try? JSON.data(obj) { body(d) }
        }
    }
}
