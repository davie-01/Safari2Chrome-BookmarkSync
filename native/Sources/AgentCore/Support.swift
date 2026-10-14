import Foundation
import CryptoKit

public enum AppInfo {
    public static let version = "0.2.0"
    /// Labels and identifiers from the pre-open-source builds; install and uninstall still
    /// clean these up so an upgrade doesn't leave two services behind.
    public static let legacyBundleID = "local.bookmarksync"
    public static let legacyAgentLabels = ["local.bookmarksync.agent", "local.bookmarksync.sync"]

    public static let bundleID = "com.mars.davie-01.BookmarkSync"
    /// per-user LaunchAgent (fallback when SMAppService refuses)
    public static let agentLabel = "\(bundleID).agent"
    /// agent embedded in BookmarkSync.app, registered through SMAppService
    public static let embeddedAgentLabel = "\(bundleID).sync"
    /// Native messaging host name: browsers only allow [a-z0-9_.], so it is not the bundle ID.
    public static let nativeHostName = "com.mars.davie_01.bookmarksync"
    public static let legacyNativeHostNames = ["local.bookmarksync"]
}

public enum Paths {
    /// Real home directory from the user database (not a sandbox container).
    public static var home: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    public static var support: URL {
        if let o = ProcessInfo.processInfo.environment["BMSYNC_SUPPORT_DIR"] { return URL(fileURLWithPath: o, isDirectory: true) }
        return home.appendingPathComponent("Library/Application Support/BookmarkSync", isDirectory: true)
    }
    public static var socket: URL { support.appendingPathComponent("agent.sock") }
    public static var state: URL { support.appendingPathComponent("state.json") }
    public static var backups: URL { support.appendingPathComponent("Backups", isDirectory: true) }
    public static var stateBackups: URL { support.appendingPathComponent("StateHistory", isDirectory: true) }
    public static var logs: URL { home.appendingPathComponent("Library/Logs/BookmarkSync", isDirectory: true) }
    public static var safariBookmarks: URL {
        if let o = ProcessInfo.processInfo.environment["BMSYNC_SAFARI_PLIST"] { return URL(fileURLWithPath: o) }
        return home.appendingPathComponent("Library/Safari/Bookmarks.plist")
    }
    public static var launchAgentPlist: URL {
        home.appendingPathComponent("Library/LaunchAgents/\(AppInfo.agentLabel).plist")
    }

    public static func ensureDir(_ url: URL, mode: Int = 0o700) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: mode])
    }
}

public func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Thread-safe append-only log. Never logs bookmark titles or URLs.
public final class Log {
    public static let shared = Log()
    private let lock = NSLock()
    private var handle: FileHandle?
    public var name = "agent"
    public var echoToStderr = false

    public func open(name: String) {
        lock.lock(); defer { lock.unlock() }
        self.name = name
        try? Paths.ensureDir(Paths.logs)
        let url = Paths.logs.appendingPathComponent("\(name).log")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > 2_000_000 {
            let old = Paths.logs.appendingPathComponent("\(name).1.log")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
    }

    public func write(_ level: String, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(name):\(getpid())] \(level) \(message)\n"
        lock.lock(); defer { lock.unlock() }
        if let d = line.data(using: .utf8) {
            handle?.write(d)
            if echoToStderr { FileHandle.standardError.write(d) }
        }
    }

    public static func info(_ m: String) { shared.write("INFO", m) }
    public static func warn(_ m: String) { shared.write("WARN", m) }
    public static func error(_ m: String) { shared.write("ERROR", m) }
}

public struct AgentError: Error, CustomStringConvertible {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
    public var description: String { "\(code): \(message)" }
}

// MARK: - JSON helpers

public enum JSON {
    public static func object(_ data: Data) throws -> [String: Any] {
        guard let o = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else {
            throw AgentError("badRequest", "expected a JSON object")
        }
        return o
    }

    public static func data(_ obj: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])
    }

    /// Codable -> JSONSerialization-compatible value
    public static func value<T: Encodable>(_ v: T) throws -> Any {
        let d = try JSONEncoder().encode(v)
        return try JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])
    }

    public static func decode<T: Decodable>(_ type: T.Type, from value: Any) throws -> T {
        let d = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return try JSONDecoder().decode(T.self, from: d)
    }
}

// MARK: - POSIX io helpers

public func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    var ok = true
    data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
        guard var p = buf.baseAddress else { return }
        var left = buf.count
        while left > 0 {
            let n = Darwin.write(fd, p, left)
            if n < 0 {
                if errno == EINTR { continue }
                ok = false
                return
            }
            left -= n
            p = p.advanced(by: n)
        }
    }
    return ok
}

/// Reads exactly `count` bytes, or returns nil on EOF/error.
public func readExactly(_ fd: Int32, _ count: Int) -> Data? {
    var out = Data(count: count)
    var got = 0
    let ok: Bool = out.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) in
        guard let base = buf.baseAddress else { return count == 0 }
        while got < count {
            let n = Darwin.read(fd, base.advanced(by: got), count - got)
            if n == 0 { return false }
            if n < 0 { if errno == EINTR { continue }; return false }
            got += n
        }
        return true
    }
    return ok ? out : nil
}

/// Newline-delimited reader over a file descriptor.
public final class LineReader {
    private let fd: Int32
    private var buffer = Data()
    private let maxLine: Int

    public init(fd: Int32, maxLine: Int = 256 * 1024 * 1024) {
        self.fd = fd
        self.maxLine = maxLine
    }

    public func next() -> Data? {
        while true {
            if let i = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<i)
                buffer.removeSubrange(buffer.startIndex...i)
                return line
            }
            if buffer.count > maxLine { return nil }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n == 0 { return nil }
            if n < 0 { if errno == EINTR { continue }; return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}

public func unixAddress(_ path: String) throws -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let cap = MemoryLayout.size(ofValue: addr.sun_path)
    guard bytes.count < cap else { throw AgentError("socketPath", "socket path too long: \(path)") }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return addr
}

public func connectUnix(_ path: String) -> Int32? {
    guard var addr = try? unixAddress(path) else { return nil }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { return nil }
    let r = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    if r != 0 { close(fd); return nil }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    return fd
}
