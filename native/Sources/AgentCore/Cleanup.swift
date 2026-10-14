import Foundation

/// Backups, logs and the sync history all grow on their own; this keeps them in check.
///
/// Rules: backups older than `backupDays` go, except the newest `keepMinBackups`, which are
/// kept however old they are. Log files older than `logDays` go, except the ones the running
/// agent has open — those are truncated instead, so the open file handle keeps working.
public enum Cleanup {
    public static let defaultBackupDays = 30
    public static let defaultLogDays = 30
    public static let defaultKeepMinBackups = 10

    /// Log files the agent writes to while running; deleting them would leave the handle
    /// pointing at an unlinked file.
    static let liveLogs: Set<String> = ["agent.log", "app.log", "agent.stderr.log", "agent.stdout.log"]

    public static func stats() -> [String: Any] {
        [
            "backups": dirStats(Paths.backups, prefix: "Bookmarks-"),
            "logs": dirStats(Paths.logs, prefix: nil),
            "state": ["bytes": size(Paths.state), "path": Paths.state.path] as [String: Any],
        ]
    }

    static func size(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
    }

    static func modified(_ url: URL) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? Date()
    }

    static func files(_ dir: URL, prefix: String?) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names
            .filter { !$0.hasPrefix(".") && (prefix == nil || $0.hasPrefix(prefix!)) }
            .map { dir.appendingPathComponent($0) }
    }

    static func dirStats(_ dir: URL, prefix: String?) -> [String: Any] {
        let all = files(dir, prefix: prefix)
        let bytes = all.reduce(0) { $0 + size($1) }
        let oldest = all.map(modified).min()
        return [
            "count": all.count,
            "bytes": bytes,
            "oldest": oldest.map { $0.timeIntervalSince1970 * 1000 } ?? 0,
            "path": dir.path,
        ]
    }

    /// what: "backups" | "logs" | "all". With dryRun, nothing is touched and the numbers
    /// say what would go.
    public static func clean(what: String = "all",
                             backupDays: Int = defaultBackupDays,
                             logDays: Int = defaultLogDays,
                             keepMinBackups: Int = defaultKeepMinBackups,
                             dryRun: Bool = false) -> [String: Any] {
        var out: [String: Any] = ["dryRun": dryRun]
        if what == "all" || what == "backups" {
            out["backups"] = cleanBackups(days: backupDays, keepMin: keepMinBackups, dryRun: dryRun)
        }
        if what == "all" || what == "logs" {
            out["logs"] = cleanLogs(days: logDays, dryRun: dryRun)
        }
        return out
    }

    static func cleanBackups(days: Int, keepMin: Int, dryRun: Bool) -> [String: Any] {
        // Names carry a timestamp (Bookmarks-20260923-101500-<fp>.plist), so sorting by name
        // is chronological; still fall back to mtime for the age test.
        let all = files(Paths.backups, prefix: "Bookmarks-").sorted { $0.lastPathComponent > $1.lastPathComponent }
        let keep = max(0, keepMin)
        let candidates = all.count > keep ? Array(all.dropFirst(keep)) : []
        let cutoff = Date().addingTimeInterval(-Double(max(0, days)) * 86400)
        var removed = 0, bytes = 0
        for f in candidates where modified(f) < cutoff {
            bytes += size(f)
            removed += 1
            if !dryRun { try? FileManager.default.removeItem(at: f) }
        }
        return ["removed": removed, "bytes": bytes, "kept": all.count - removed]
    }

    static func cleanLogs(days: Int, dryRun: Bool) -> [String: Any] {
        let cutoff = Date().addingTimeInterval(-Double(max(0, days)) * 86400)
        var removed = 0, bytes = 0, truncated = 0
        for f in files(Paths.logs, prefix: nil) where modified(f) < cutoff {
            let n = size(f)
            if liveLogs.contains(f.lastPathComponent) {
                guard n > 0 else { continue }
                bytes += n
                truncated += 1
                if !dryRun, let h = try? FileHandle(forWritingTo: f) {
                    try? h.truncate(atOffset: 0)
                    try? h.close()
                }
            } else {
                bytes += n
                removed += 1
                if !dryRun { try? FileManager.default.removeItem(at: f) }
            }
        }
        return ["removed": removed, "truncated": truncated, "bytes": bytes]
    }

    /// Human-readable one-liner for the log.
    public static func describe(_ report: [String: Any]) -> String {
        var parts: [String] = []
        for key in ["backups", "logs"] {
            guard let r = report[key] as? [String: Any] else { continue }
            let removed = (r["removed"] as? Int ?? 0) + (r["truncated"] as? Int ?? 0)
            if removed > 0 { parts.append("\(key) \(removed) files, \(r["bytes"] as? Int ?? 0) bytes") }
        }
        return parts.isEmpty ? "nothing to clean" : parts.joined(separator: "; ")
    }
}
