import SwiftUI
import AgentCore

enum AppTab: String, CaseIterable, Identifiable {
    case sync, endpoints, rules, permissions, advanced
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sync: return t("同步")
        case .endpoints: return t("端")
        case .rules: return t("规则")
        case .permissions: return t("权限")
        case .advanced: return t("高级")
        }
    }
    var icon: String {
        switch self {
        case .sync: return "arrow.triangle.2.circlepath"
        case .endpoints: return "laptopcomputer.and.iphone"
        case .rules: return "slider.horizontal.3"
        case .permissions: return "lock.shield"
        case .advanced: return "gearshape"
        }
    }
}

struct RootApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var link = AgentLink.shared
    @AppStorage(MenuBarPref.key) private var menuBar = true

    var body: some Scene {
        Window("BookmarkSync", id: "main") {
            MainWindow().environmentObject(link)
        }
        .defaultSize(width: 820, height: 600)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button(t("设置…")) { showMainWindow(.rules) }.keyboardShortcut(",")
            }
            CommandGroup(after: .appInfo) {
                Button(t("立即同步")) { link.syncNow() }.keyboardShortcut("r")
                Button(t("打开备份文件夹")) { link.reveal("backups") }
                Button(t("打开日志文件夹")) { link.reveal("logs") }
            }
        }

        MenuBarExtra("BookmarkSync", systemImage: menuIcon, isInserted: $menuBar) {
            MenuBarMenu().environmentObject(link)
        }
    }

    private var menuIcon: String {
        guard link.connected else { return "bookmark" }
        return (link.pending?.count ?? 0) > 0 ? "bookmark.fill" : "bookmark"
    }
}

/// Brings the single window back (⌘Q only hides it) and optionally switches page.
@MainActor func showMainWindow(_ tab: AppTab? = nil) {
    if let tab = tab { AgentLink.shared.tab = tab }
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    if let w = NSApp.windows.first(where: { $0.canBecomeMain && $0.title == "BookmarkSync" }) {
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(nil)
    } else {
        NSApp.sendAction(Selector(("newWindowForTab:")), to: nil, from: nil)
    }
}

enum MenuBarPref {
    static let key = "menuBarIcon"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Only the menu bar's t("退出 BookmarkSync") really quits; ⌘Q just puts the app away.
    private static var quitting = false

    static func reallyQuit() {
        quitting = true
        NSApp.terminate(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("app UI started (\(AppInfo.version))")
        AgentLink.shared.start()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.updateQuitTitle()
            NSApp.windows.first(where: { $0.isVisible })?.makeFirstResponder(nil)
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.updateQuitTitle() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Without the menu bar icon there would be no way back, so then ⌘Q really quits.
        guard !AppDelegate.quitting, MenuBarPref.enabled else { return .terminateNow }
        DispatchQueue.main.async {
            for w in NSApp.windows where w.isVisible && w.canBecomeMain { w.orderOut(nil) }
            NSApp.setActivationPolicy(.accessory) // no Dock icon while it lives in the menu bar
        }
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !MenuBarPref.enabled
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { showMainWindow() } }
        return true
    }

    /// Say what ⌘Q will actually do.
    func updateQuitTitle() {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
              let item = appMenu.items.last(where: {
                  $0.action == #selector(NSApplication.terminate(_:))
                      || ($0.keyEquivalent == "q" && $0.keyEquivalentModifierMask == [.command])
              }) else { return }
        item.title = MenuBarPref.enabled ? t("关闭界面（后台继续同步）") : t("退出 BookmarkSync")
    }

    func applicationWillTerminate(_ notification: Notification) {
        AgentSupervisor.shared.stopTemporary()
    }
}

struct MenuBarMenu: View {
    @EnvironmentObject var link: AgentLink

    var body: some View {
        Text(link.connected ? t("后台服务运行中") : t("后台服务未连接"))
        if let p = link.pending, p.count > 0 { Text(t("待确认 {n} 项", ["n": p.count])) }
        Divider()
        Button(link.busy ?? t("立即同步")) { link.syncNow() }.disabled(link.busy != nil || !link.connected)
        Toggle(t("自动同步"), isOn: Binding(get: { link.settings.autoSync },
                                     set: { link.save(["autoSync": $0]) })).disabled(!link.connected)
        Divider()
        Button(t("打开主窗口")) { showMainWindow(.sync) }
        Button(t("设置…")) { showMainWindow(.rules) }
        Divider()
        Button(t("退出 BookmarkSync")) { AppDelegate.reallyQuit() }
    }
}
