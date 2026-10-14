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
        func attach(_ s: Int32) {
            // tell the agent which browser we belong to before relaying anything
            if let d = try? JSON.data(["type": "host.hello", "browserPath": browserPath ?? "", "origin": origin]) {
                _ = writeAll(s, d + Data([0x0A]))
            }
            startSocketReader(s, out: out)
        }
        var sock = connectWithRetry()
        if sock == nil {
            Log.warn("agent not reachable at \(Paths.socket.path)")
        }
        if let s = sock { attach(s) }

        while true {
            guard let lenData = readExactly(STDIN_FILENO, 4) else { break }
            let len = lenData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
            guard len > 0, len < 64 * 1024 * 1024, let msg = readExactly(STDIN_FILENO, Int(len)) else { break }
            if sock == nil {
                sock = connectWithRetry()
                if let s = sock { attach(s) }
            }
            guard let s = sock else {
                replyAgentUnavailable(msg, out: out)
                continue
            }
            var line = msg
            line.append(0x0A)
            if !writeAll(s, line) {
                close(s)
                sock = nil
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

    static func connectWithRetry() -> Int32? {
        for attempt in 0..<15 {
            if let fd = connectUnix(Paths.socket.path) { return fd }
            if attempt == 0 { kickstartAgent() }
            usleep(200_000)
        }
        return nil
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

    static func startSocketReader(_ fd: Int32, out: FrameWriter) {
        Thread.detachNewThread {
            let reader = LineReader(fd: fd)
            while let line = reader.next() {
                if line.isEmpty { continue }
                out.sendChunked(line)
            }
            Log.warn("agent connection closed")
            // Tell the extension; it will reconnect (Chrome restarts the host).
            if let d = try? JSON.data(["event": "agent.disconnected"]) { out.send(d) }
            exit(0)
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

    public func sendChunked(_ payload: Data) {
        for f in FrameWriter.frames(for: payload) { send(f) }
    }

    /// Splits a message that would exceed Chrome's 1 MB limit into base64 chunks.
    public static func frames(for payload: Data, limit: Int = NativeHost.maxFrame - 1024, chunk: Int = NativeHost.chunkPayload) -> [Data] {
        if payload.count <= limit { return [payload] }
        let cid = UUID().uuidString
        let total = (payload.count + chunk - 1) / chunk
        var out: [Data] = []
        for seq in 0..<total {
            let start = seq * chunk
            let end = min(payload.count, start + chunk)
            let b64 = payload.subdata(in: start..<end).base64EncodedString()
            let obj: [String: Any] = ["chunk": ["cid": cid, "seq": seq, "total": total, "b64": b64]]
            if let d = try? JSON.data(obj) { out.append(d) }
        }
        return out
    }
}
