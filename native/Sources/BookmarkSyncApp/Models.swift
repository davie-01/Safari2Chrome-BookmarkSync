import Foundation

/// Mirrors extension/engine/coordinator.js DEFAULT_SETTINGS plus safariPath, which the agent
/// reads. Unknown keys stay in settings.json: the app always sends patches, never the whole
/// object. App-only preferences (menu bar icon) live in UserDefaults instead.
struct EngineSettings: Codable, Equatable {
    var autoSync = false
    var autoDelay = 5
    var syncOrder = true
    var safariWhileRunning = true
    var autoDelete = false
    var autoDeleteMax = 5
    var orderMaster: String?
    var safariPath: String?
    var backupDays: Int?
    var logDays: Int?
    var backupKeepMin: Int?
    var autoClean: Bool?
    var language: String?
    var endpoints: [String: EndpointPrefs] = [:]

    func prefs(_ id: String) -> EndpointPrefs { endpoints[id] ?? EndpointPrefs() }
}

struct EndpointPrefs: Codable, Equatable, Hashable {
    var enabled: Bool?
    var mode: String?
    var chromeStore: String?
    var name: String?

    var isEnabled: Bool { enabled ?? true }
    var syncMode: SyncMode { SyncMode(rawValue: mode ?? "both") ?? .both }
}

enum SyncMode: String, CaseIterable, Identifiable {
    case both, receive, send
    var id: String { rawValue }
    var label: String {
        switch self {
        case .both: return t("双向")
        case .receive: return t("只接收")
        case .send: return t("只发送")
        }
    }
    var help: String {
        switch self {
        case .both: return t("这一端的改动会传出去，其他端的改动也会写进来")
        case .receive: return t("只把其他端的改动写进来，这一端的改动不传出去")
        case .send: return t("只把这一端的改动传出去，不接收其他端的改动")
        }
    }
}

struct EndpointInfo: Codable, Identifiable, Hashable {
    var id: String
    var kind: String
    var browser: String?
    var name: String
    var online: Bool?
    var isOnline: Bool { online ?? false }
    var isSafari: Bool { kind == "safari" }
}

struct AgentStatus: Codable {
    var version: String
    var agentPid: Int
    var executable: String
    var safariPath: String
    var safariAccess: String
    var safariRunning: Bool
    var engine: Bool
    var supportDir: String
    var endpoints: [EndpointInfo]

    var safariReadable: Bool { safariAccess == "ok" }
    var accessLabel: String {
        switch safariAccess {
        case "ok": return t("已授权")
        case "noFullDiskAccess": return t("缺少完全磁盘访问权限")
        case "missing": return t("找不到书签文件")
        default: return safariAccess
        }
    }
}

struct PendingInfo: Codable {
    var items: Int?
    var conflicts: Int?
    var heldDeletes: Int?
    var heldOrders: Int?
    var at: Double?
    var count: Int { items ?? 0 }
}

struct DirStats: Codable {
    var count: Int?
    var bytes: Int?
    var oldest: Double?
    var path: String?

    var files: Int { count ?? 0 }
    var size: Int { bytes ?? 0 }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }
    var oldestDate: Date? { (oldest ?? 0) > 0 ? Date(timeIntervalSince1970: oldest! / 1000) : nil }
}

struct StorageStats: Codable {
    var backups: DirStats?
    var logs: DirStats?
    var state: DirStats?
}

struct CleanReport: Codable {
    struct Part: Codable { var removed: Int?; var truncated: Int?; var bytes: Int?; var kept: Int? }
    var dryRun: Bool?
    var backups: Part?
    var logs: Part?

    var files: Int { (backups?.removed ?? 0) + (logs?.removed ?? 0) + (logs?.truncated ?? 0) }
    var bytes: Int { (backups?.bytes ?? 0) + (logs?.bytes ?? 0) }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
}
