import Foundation

/// Persists the engine's sync state (mappings + agreed base) as opaque JSON with an
/// optimistic revision counter, atomic writes and a short history for manual recovery.
public final class StateStore {
    public let url: URL
    public let historyDir: URL

    public init(url: URL = Paths.state, historyDir: URL = Paths.stateBackups) {
        self.url = url
        self.historyDir = historyDir
    }

    public func load() throws -> (state: Any?, revision: Int) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (nil, 0) }
        let obj = try JSON.object(try Data(contentsOf: url))
        return (obj["state"], obj["revision"] as? Int ?? 0)
    }

    public func save(_ state: Any, expectedRevision: Int) throws -> Int {
        let current = try load().revision
        guard current == expectedRevision else {
            throw AgentError("staleState", "同步状态已被其他会话更新（revision \(current) ≠ \(expectedRevision)），请重新扫描")
        }
        let next = current + 1
        let payload: [String: Any] = ["revision": next, "savedAt": ISO8601DateFormatter().string(from: Date()), "state": state]
        let data = try JSON.data(payload)
        try Paths.ensureDir(url.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: url.path) {
            try? Paths.ensureDir(historyDir)
            let h = historyDir.appendingPathComponent(String(format: "state-%08d.json", current))
            try? FileManager.default.removeItem(at: h)
            try? FileManager.default.copyItem(at: url, to: h)
            prune(keep: 20)
        }
        try data.write(to: url, options: [.atomic])
        chmod(url.path, 0o600)
        return next
    }

    public func reset() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let cur = try load().revision
            try? Paths.ensureDir(historyDir)
            let h = historyDir.appendingPathComponent(String(format: "state-%08d-reset.json", cur))
            try? FileManager.default.copyItem(at: url, to: h)
            try FileManager.default.removeItem(at: url)
        }
    }

    private func prune(keep: Int) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: historyDir.path) else { return }
        for n in names.filter({ $0.hasPrefix("state-") }).sorted().dropLast(keep) {
            try? fm.removeItem(at: historyDir.appendingPathComponent(n))
        }
    }
}
