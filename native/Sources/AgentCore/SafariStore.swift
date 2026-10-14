import Foundation
import AppKit
import SafariBookmarks

/// Reads and writes Safari's Bookmarks.plist with the safety gates from the handoff:
/// Safari must be quit, read -> apply on a copy -> fidelity check -> backup -> re-check
/// fingerprint -> same-directory temp file + rename -> re-read and verify.
public final class SafariStore {
    public let url: URL
    public let isRealSafariFile: Bool

    public init(url: URL = Paths.safariBookmarks) {
        self.url = url
        self.isRealSafariFile = url.standardizedFileURL.path == Paths.home.appendingPathComponent("Library/Safari/Bookmarks.plist").path
    }

    public static func safariRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").isEmpty
    }

    public enum Access: String { case ok, noFullDiskAccess, missing, error }

    public func access() -> Access {
        let fd = open(url.path, O_RDONLY)
        if fd >= 0 { close(fd); return .ok }
        switch errno {
        case EPERM, EACCES: return .noFullDiskAccess
        case ENOENT: return .missing
        default: return .error
        }
    }

    public struct Snapshot {
        public let data: Data
        public let fingerprint: String
        public let mtime: Date?
    }

    public func read() throws -> Snapshot {
        switch access() {
        case .ok: break
        case .noFullDiskAccess:
            throw AgentError("noFullDiskAccess", "无法读取 Safari 书签：请在 系统设置 → 隐私与安全性 → 完全磁盘访问权限 中允许 BookmarkSync")
        case .missing: throw AgentError("safariFileMissing", "找不到 \(url.path)")
        case .error: throw AgentError("readFailed", "读取失败 errno=\(errno)")
        }
        let data = try Data(contentsOf: url)
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        return Snapshot(data: data, fingerprint: sha256Hex(data), mtime: mtime)
    }

    public func stat() -> (mtime: TimeInterval, size: Int)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return ((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0, (a[.size] as? Int) ?? 0)
    }

    public struct ReadResult: Encodable {
        public let tree: NormTree
        public let stats: TreeStats
        public let fingerprint: String
    }

    public func readNormalized() throws -> ReadResult {
        let snap = try read()
        let doc = try SafariDocument(data: snap.data)
        let (tree, stats) = try doc.normalized()
        return ReadResult(tree: tree, stats: stats, fingerprint: snap.fingerprint)
    }

    public struct ApplyResult: Encodable {
        public let tree: NormTree
        public let stats: TreeStats
        public let fingerprint: String
        public let backup: String?
        public let applied: Int
    }

    public struct ApplyOptions {
        public var allowWhileSafariRunning = false
        public var backup = true
        public init() {}
    }

    public func apply(_ ops: [SafariOp], options: ApplyOptions = ApplyOptions()) throws -> ApplyResult {
        if ops.isEmpty {
            let r = try readNormalized()
            return ApplyResult(tree: r.tree, stats: r.stats, fingerprint: r.fingerprint, backup: nil, applied: 0)
        }
        if isRealSafariFile && !options.allowWhileSafariRunning && Self.safariRunning() {
            throw AgentError("safariRunning", "Safari 正在运行。请完全退出 Safari（⌘Q）后再写入。")
        }
        let before = try read()
        let original = try SafariDocument(data: before.data)
        let modified = original.copy()
        let touched: Set<String>
        do {
            touched = try modified.apply(ops)
        } catch let e as SafariBookmarkError {
            throw AgentError(e.code, e.description)
        }
        let problems = SafariDocument.fidelityProblems(original: original, modified: modified, touched: touched)
        if !problems.isEmpty {
            throw AgentError("fidelity", "写入会改动未涉及的数据，已取消：\(problems.prefix(5).joined(separator: "; "))")
        }
        let out = try modified.serialize()
        let expected = try modified.normalized().tree
        // serialization round trip must be lossless for the synced view
        guard try SafariDocument(data: out).normalized().tree == expected else {
            throw AgentError("roundTrip", "序列化复读不一致，已取消")
        }

        var backupPath: String?
        if options.backup {
            backupPath = try writeBackup(before)
        }

        // the file must not have changed while we were working (Safari/iCloud agents)
        let again = try read()
        guard again.fingerprint == before.fingerprint else {
            throw AgentError("concurrentModification", "Safari 书签文件在准备期间被其他进程修改，已取消，请重新扫描")
        }
        if isRealSafariFile && !options.allowWhileSafariRunning && Self.safariRunning() {
            throw AgentError("safariRunning", "Safari 在写入前启动了，已取消")
        }
        try atomicReplace(with: out)

        let after = try read()
        let afterDoc = try SafariDocument(data: after.data)
        let (tree, stats) = try afterDoc.normalized()
        guard tree == expected else {
            Log.error("verify mismatch after write; backup=\(backupPath ?? "-")")
            throw AgentError("verifyFailed", "写入后复读与预期不一致。未自动回滚；备份：\(backupPath ?? "无")")
        }
        Log.info("safari apply ok ops=\(ops.count) fp=\(after.fingerprint.prefix(12)) backup=\(backupPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "-")")
        return ApplyResult(tree: tree, stats: stats, fingerprint: after.fingerprint, backup: backupPath, applied: ops.count)
    }

    private func writeBackup(_ snap: Snapshot) throws -> String {
        try Paths.ensureDir(Paths.backups)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let name = "Bookmarks-\(f.string(from: Date()))-\(snap.fingerprint.prefix(8)).plist"
        let dest = Paths.backups.appendingPathComponent(name)
        try snap.data.write(to: dest, options: [.atomic])
        chmod(dest.path, 0o600)
        pruneBackups(keep: 60)
        return dest.path
    }

    private func pruneBackups(keep: Int) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: Paths.backups.path) else { return }
        let sorted = names.filter { $0.hasPrefix("Bookmarks-") }.sorted()
        for n in sorted.dropLast(keep) { try? fm.removeItem(at: Paths.backups.appendingPathComponent(n)) }
    }

    private func atomicReplace(with data: Data) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).bmsync-\(getpid()).tmp")
        let perms = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber
        let mode = mode_t(perms?.uint16Value ?? 0o644)
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC | O_EXCL, mode)
        guard fd >= 0 else { throw AgentError("writeFailed", "无法创建临时文件 errno=\(errno)") }
        let ok = writeAll(fd, data)
        let synced = fsync(fd) == 0
        close(fd)
        guard ok, synced else {
            unlink(tmp.path)
            throw AgentError("writeFailed", "写入临时文件失败")
        }
        chmod(tmp.path, mode)
        if rename(tmp.path, url.path) != 0 {
            let e = errno
            unlink(tmp.path)
            throw AgentError("writeFailed", "替换文件失败 errno=\(e)")
        }
        let dfd = open(dir.path, O_RDONLY)
        if dfd >= 0 { fsync(dfd); close(dfd) }
    }

}
