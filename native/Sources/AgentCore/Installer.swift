import Foundation
import ServiceManagement

/// Registers the LaunchAgent and the Chrome native messaging host manifest.
public enum Installer {
    /// Fixed ID derived from the public key in extension/manifest.json ("key").
    public static let defaultExtensionID = "dllnilcheahcklaiheddleegbdalbcjn"

    /// The CLI/agent/native-host binary inside the bundle. From the SwiftUI app the bundle
    /// executable is BookmarkSync, so the manifests and the LaunchAgent must point at `bmsync`.
    public static var helperPath: String {
        let exe = URL(fileURLWithPath: executablePath)
        let sibling = exe.deletingLastPathComponent().appendingPathComponent("bmsync")
        if exe.lastPathComponent != "bmsync", FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling.path }
        return exe.path
    }

    public static var executablePath: String {
        let raw = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
    }

    /// Chromium-based browsers and their per-user data directories (NativeMessagingHosts lives inside).
    static let chromiumDirs: [(name: String, rel: String)] = [
        ("Google Chrome", "Library/Application Support/Google/Chrome"),
        ("Google Chrome Beta", "Library/Application Support/Google/Chrome Beta"),
        ("Google Chrome Dev", "Library/Application Support/Google/Chrome Dev"),
        ("Google Chrome Canary", "Library/Application Support/Google/Chrome Canary"),
        ("Chromium", "Library/Application Support/Chromium"),
        ("Microsoft Edge", "Library/Application Support/Microsoft Edge"),
        ("Microsoft Edge Beta", "Library/Application Support/Microsoft Edge Beta"),
        ("Microsoft Edge Dev", "Library/Application Support/Microsoft Edge Dev"),
        ("Microsoft Edge Canary", "Library/Application Support/Microsoft Edge Canary"),
        ("Brave", "Library/Application Support/BraveSoftware/Brave-Browser"),
        ("Vivaldi", "Library/Application Support/Vivaldi"),
        ("Arc", "Library/Application Support/Arc/User Data"),
        ("Opera", "Library/Application Support/com.operasoftware.Opera"),
        ("Yandex", "Library/Application Support/Yandex/YandexBrowser"),
    ]
    static var chromeDirs: [String] { chromiumDirs.map(\.rel) }

    static func manifestData(extensionIDs: [String]) throws -> Data {
        let manifest: [String: Any] = [
            "name": AppInfo.nativeHostName,
            "description": "BookmarkSync native host (relays to the local agent)",
            "path": helperPath,
            "type": "stdio",
            "allowed_origins": extensionIDs.map { "chrome-extension://\($0)/" },
        ]
        return try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
    }

    /// Writes the native host manifest for every installed Chromium browser (Google Chrome
    /// always). Called on install and periodically by the agent, so a browser installed
    /// later is picked up. Returns written paths.
    /// Older builds used a different host name; drop those so a browser doesn't keep two.
    static func removeLegacyManifests() {
        for d in chromiumDirs {
            for name in AppInfo.legacyNativeHostNames {
                let f = Paths.home.appendingPathComponent(d.rel)
                    .appendingPathComponent("NativeMessagingHosts/\(name).json")
                try? FileManager.default.removeItem(at: f)
            }
        }
    }

    @discardableResult
    public static func refreshNativeHostManifests(extensionIDs: [String]? = nil) -> [String] {
        let ids = extensionIDs ?? storedExtensionIDs()
        guard let mdata = try? manifestData(extensionIDs: ids) else { return [] }
        removeLegacyManifests()
        var wrote: [String] = []
        for (i, d) in chromiumDirs.enumerated() {
            let base = Paths.home.appendingPathComponent(d.rel, isDirectory: true)
            guard i == 0 || FileManager.default.fileExists(atPath: base.path) else { continue }
            let dir = base.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
            let file = dir.appendingPathComponent("\(AppInfo.nativeHostName).json")
            if (try? Data(contentsOf: file)) == mdata { wrote.append(file.path); continue }
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try mdata.write(to: file, options: [.atomic])
                wrote.append(file.path)
            } catch {
                Log.warn("cannot write native host manifest for \(d.name): \(error.localizedDescription)")
            }
        }
        return wrote
    }

    static var extensionIDsFile: URL { Paths.support.appendingPathComponent("extension-ids.json") }

    static func storedExtensionIDs() -> [String] {
        if let d = try? Data(contentsOf: extensionIDsFile), let a = try? JSONDecoder().decode([String].self, from: d), !a.isEmpty { return a }
        return [defaultExtensionID]
    }

    public static func install(extensionIDs: [String], launchAgent: Bool = true) throws -> [String] {
        let extensionIDs = extensionIDs.isEmpty ? storedExtensionIDs() : extensionIDs
        var report: [String] = []
        let exe = helperPath
        if !exe.contains(".app/Contents/MacOS/") {
            report.append("⚠️  当前二进制不在 .app 包内（\(exe)）。完全磁盘访问权限最好授予 BookmarkSync.app，建议用 scripts/build-app.sh 安装。")
        }
        try Paths.ensureDir(Paths.support)
        try Paths.ensureDir(Paths.logs)

        // Native messaging host manifest(s) for every installed Chromium browser
        try? JSONEncoder().encode(extensionIDs).write(to: extensionIDsFile, options: [.atomic])
        let wrote = refreshNativeHostManifests(extensionIDs: extensionIDs)
        for f in wrote { report.append("✓ Native host 清单：\(f)") }
        if wrote.isEmpty { report.append("⚠️ 没有写入任何 Native host 清单") }

        if launchAgent {
            // Preferred: agent embedded in the app bundle, registered with SMAppService, so
            // 登录项与扩展 lists it as "BookmarkSync". If the system refuses (e.g. the item was
            // switched off there), fall back to the per-user LaunchAgent so sync keeps running.
            // Re-register even when already enabled: launchd keeps a snapshot of the app
            // bundle, so after an upgrade the old record can fail to spawn (EX_CONFIG).
            let svc = embeddedService
            if svc.status == .enabled { try? svc.unregister(); usleep(400_000) }
            var registered = false
            do { try svc.register(); registered = svc.status == .enabled || svc.status == .requiresApproval }
            catch { report.append("⚠️ SMAppService 注册失败：\(error.localizedDescription)（\(describe(svc.status))）") }
            if registered {
                for label in AppInfo.legacyAgentLabels {
                    _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
                }
                if FileManager.default.fileExists(atPath: Paths.launchAgentPlist.path) {
                    _ = launchctl(["bootout", "gui/\(getuid())/\(AppInfo.agentLabel)"])
                    try? FileManager.default.removeItem(at: Paths.launchAgentPlist)
                }
                report.append("✓ 后台服务：\(describe(svc.status))（登录项中显示为 BookmarkSync）")
                if svc.status == .requiresApproval {
                    report.append("→ 请在 系统设置 → 通用 → 登录项与扩展 里打开 BookmarkSync 的开关")
                }
            } else {
                try installLegacyAgent(exe: exe)
                report.append("✓ 后台服务：已用旧方式加载（登录项中显示为证书开发者名）。在 登录项与扩展 里打开 BookmarkSync 后，重新执行 install 即可切换")
            }
        }
        report.append("→ 下一步：在 系统设置 → 隐私与安全性 → 完全磁盘访问权限 中加入并勾选 BookmarkSync.app，然后执行 `bmsync status` 检查。")
        return report
    }

    static func installLegacyAgent(exe: String) throws {
        let plist: [String: Any] = [
            "Label": AppInfo.agentLabel,
            "ProgramArguments": [exe, "agent"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "AssociatedBundleIdentifiers": [AppInfo.bundleID],
        ]
        let pdata = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: Paths.launchAgentPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pdata.write(to: Paths.launchAgentPlist, options: [.atomic])
        _ = launchctl(["bootout", "gui/\(getuid())/\(AppInfo.agentLabel)"])
        _ = launchctl(["bootstrap", "gui/\(getuid())", Paths.launchAgentPlist.path])
    }

    public static func describe(_ st: SMAppService.Status) -> String {
        switch st {
        case .enabled: return "已启用"
        case .requiresApproval: return "等待在登录项中批准"
        case .notRegistered: return "未注册"
        case .notFound: return "App 包内找不到服务配置"
        @unknown default: return "未知"
        }
    }

    static var embeddedService: SMAppService { SMAppService.agent(plistName: "\(AppInfo.embeddedAgentLabel).plist") }

    /// Is the background service registered to run at login (and keep running)?
    public static var residentEnabled: Bool {
        let st = embeddedService.status
        if st == .enabled || st == .requiresApproval { return true }
        return FileManager.default.fileExists(atPath: Paths.launchAgentPlist.path)
    }

    /// Turns the resident background service on or off. Returns a short status line.
    @discardableResult
    public static func setResident(_ on: Bool) throws -> String {
        if on {
            let report = try install(extensionIDs: storedExtensionIDs(), launchAgent: true)
            return report.first { $0.contains("后台服务") } ?? describe(embeddedService.status)
        }
        try? embeddedService.unregister()
        _ = launchctl(["bootout", "gui/\(getuid())/\(AppInfo.agentLabel)"])
        try? FileManager.default.removeItem(at: Paths.launchAgentPlist)
        _ = launchctl(["kill", "TERM", "gui/\(getuid())/\(AppInfo.embeddedAgentLabel)"])
        return "已关闭常驻（\(describe(embeddedService.status))）"
    }

    /// Restarts the resident service so it picks up changed settings.
    public static func kickstartResident() {
        _ = launchctl(["kickstart", "-k", "gui/\(getuid())/\(AppInfo.embeddedAgentLabel)"])
    }

    public static var agentStatus: String {
        describe(SMAppService.agent(plistName: "\(AppInfo.embeddedAgentLabel).plist").status)
    }

    public static func uninstall() -> [String] {
        var report: [String] = []
        try? SMAppService.agent(plistName: "\(AppInfo.embeddedAgentLabel).plist").unregister()
        _ = launchctl(["bootout", "gui/\(getuid())/\(AppInfo.agentLabel)"])
        try? FileManager.default.removeItem(at: Paths.launchAgentPlist)
        report.append("✓ 已注销后台服务")
        for rel in chromeDirs {
            let f = Paths.home.appendingPathComponent(rel).appendingPathComponent("NativeMessagingHosts/\(AppInfo.nativeHostName).json")
            if FileManager.default.fileExists(atPath: f.path) {
                try? FileManager.default.removeItem(at: f)
                report.append("✓ 已移除 \(f.path)")
            }
        }
        report.append("（同步状态与备份保留在 \(Paths.support.path)，如需彻底清除请手动删除）")
        return report
    }

    @discardableResult
    public static func launchctl(_ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, out.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
