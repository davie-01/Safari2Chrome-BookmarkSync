import Foundation
import ServiceManagement

/// Removes every trace of BookmarkSync from this Mac: the background service registration,
/// the native messaging manifests in every browser, the sync state, backups, logs, and the
/// app's own preferences and caches. The browser extension has to be removed by hand — no
/// app can uninstall it.
///
/// The same code runs in two situations: the user picks 卸载 in the app, and the agent
/// notices its app bundle is gone (dragged to the Trash) and cleans up after itself.
public enum Uninstall {
    public struct Item {
        public let path: String
        public let label: String
        public let bytes: Int
        public let isDirectory: Bool
    }

    public struct Report {
        public var removed: [String] = []
        public var failed: [(path: String, error: String)] = []
        public var appTrashed = false
        public var residue: [String] = []
        public var bytes = 0
    }

    // MARK: what will go

    static var appBundle: URL? {
        let exe = URL(fileURLWithPath: Installer.executablePath)
        // …/BookmarkSync.app/Contents/MacOS/<binary>
        let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? app : nil
    }

    static func home(_ rel: String) -> URL { Paths.home.appendingPathComponent(rel) }

    /// Everything except the app bundle itself (that one is moved to the Trash last).
    public static func targets() -> [(url: URL, label: String)] {
        var out: [(URL, String)] = [
            (Paths.support, "同步状态、备份、设置"),
            (Paths.logs, "日志"),
            (Paths.launchAgentPlist, "旧版后台服务配置"),
            (home("Library/Preferences/\(AppInfo.bundleID).plist"), "偏好设置"),
            (home("Library/Caches/\(AppInfo.bundleID)"), "缓存"),
            (home("Library/HTTPStorages/\(AppInfo.bundleID)"), "网页界面缓存"),
            (home("Library/HTTPStorages/\(AppInfo.bundleID).binarycookies"), "网页界面缓存"),
            (home("Library/WebKit/\(AppInfo.bundleID)"), "网页界面数据"),
            (home("Library/Saved Application State/\(AppInfo.bundleID).savedState"), "窗口状态"),
        ]
        for dir in Installer.chromiumDirs {
            for name in [AppInfo.nativeHostName] + AppInfo.legacyNativeHostNames {
                out.append((Paths.home.appendingPathComponent(dir.rel)
                    .appendingPathComponent("NativeMessagingHosts/\(name).json"),
                    "\(dir.name) 的连接配置"))
            }
        }
        // anything the pre-open-source builds left under the old identifier
        for rel in ["Library/Preferences/\(AppInfo.legacyBundleID).plist",
                    "Library/Caches/\(AppInfo.legacyBundleID)",
                    "Library/HTTPStorages/\(AppInfo.legacyBundleID)",
                    "Library/HTTPStorages/\(AppInfo.legacyBundleID).binarycookies",
                    "Library/WebKit/\(AppInfo.legacyBundleID)",
                    "Library/Saved Application State/\(AppInfo.legacyBundleID).savedState"] {
            out.append((home(rel), "旧版本残留"))
        }
        return out.map { (url: $0.0, label: $0.1) }
    }

    /// What exists right now, for the confirmation dialog.
    public static func plan() -> [Item] {
        targets().compactMap { t in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: t.url.path, isDirectory: &isDir) else { return nil }
            return Item(path: t.url.path, label: t.label, bytes: size(of: t.url), isDirectory: isDir.boolValue)
        }
    }

    static func size(of url: URL) -> Int {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? Int) ?? 0
        }
        var total = 0
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in e {
                total += (try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            }
        }
        return total
    }

    // MARK: doing it

    /// Stops the background service, deletes everything above, and (from the app) moves the
    /// bundle to the Trash. Never asks; the caller has already confirmed.
    @discardableResult
    public static func run(trashApp: Bool) -> Report {
        var report = Report()
        Log.info("uninstall: starting (trashApp=\(trashApp))")

        // 1. stop and unregister the background service
        try? SMAppService.agent(plistName: "\(AppInfo.embeddedAgentLabel).plist").unregister()
        for label in [AppInfo.agentLabel, AppInfo.embeddedAgentLabel] + AppInfo.legacyAgentLabels {
            _ = Installer.launchctl(["bootout", "gui/\(getuid())/\(label)"])
            _ = Installer.launchctl(["kill", "TERM", "gui/\(getuid())/\(label)"])
        }
        for label in AppInfo.legacyAgentLabels {
            try? SMAppService.agent(plistName: "\(label).plist").unregister()
        }

        // 2. files
        let fm = FileManager.default
        for t in targets() where fm.fileExists(atPath: t.url.path) {
            let n = size(of: t.url)
            do {
                try fm.removeItem(at: t.url)
                report.removed.append(t.url.path)
                report.bytes += n
            } catch {
                report.failed.append((t.url.path, error.localizedDescription))
            }
        }

        // 3. the app itself
        if trashApp, let app = appBundle {
            var trashed: NSURL?
            do {
                try fm.trashItem(at: app, resultingItemURL: &trashed)
                report.appTrashed = true
                report.removed.append(app.path)
            } catch {
                report.failed.append((app.path, error.localizedDescription))
            }
        }

        report.residue = residue()
        Log.info("uninstall: removed \(report.removed.count) items, \(report.failed.count) failed, residue \(report.residue.count)")
        return report
    }

    /// Anything still on disk after a run — should be empty.
    public static func residue() -> [String] {
        var left = targets().map(\.url).filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.path)
        if SMAppService.agent(plistName: "\(AppInfo.embeddedAgentLabel).plist").status == .enabled {
            left.append("登录项：\(AppInfo.embeddedAgentLabel)")
        }
        return left
    }

    // MARK: self-clean

    /// True when the app bundle this agent came from is no longer where it was (dragged to
    /// the Trash, or deleted). An upgrade replaces the bundle within seconds, so callers
    /// must see this twice, far apart, before acting.
    public static func appBundleMissing() -> Bool {
        guard let app = appBundle else { return false }
        return !FileManager.default.fileExists(atPath: app.path)
    }
}
