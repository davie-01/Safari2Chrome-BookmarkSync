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

/// SwiftUI's own action for (re)opening the main window scene, kept from a view that has it.
/// Once the window was closed (red button) the scene is gone: ordering the old NSWindow to
/// the front does not bring it back, only openWindow does. It also fronts a hidden window.
@MainActor enum MainWindowOpener {
    static var open: OpenWindowAction?
}

/// Brings the single window back (closed with ⌘W or the red button, or hidden) and optionally
/// switches page.
@MainActor func showMainWindow(_ tab: AppTab? = nil) {
    if let tab = tab { AgentLink.shared.tab = tab }
    AgentLink.shared.uiVisible = true
    // From the menu bar the app is an accessory (no Dock icon), is not the active app and its
    // menu is still closing. Asking to be activated right then can be declined, and a window
    // ordered front by an inactive app stays behind the active app's windows. So: become a
    // regular app, let that and the menu settle for a turn of the run loop, then open, activate
    // and, should activation still be declined, put the window in front regardless.
    NSApp.setActivationPolicy(.regular)
    DispatchQueue.main.async {
        if let open = MainWindowOpener.open {
            open(id: "main")
        } else if let w = mainWindow() {
            w.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        // openWindow may build the window on the next turn of the run loop
        DispatchQueue.main.async {
            guard let w = mainWindow() else { return }
            w.makeKeyAndOrderFront(nil)
            if !NSApp.isActive { w.orderFrontRegardless() }
            w.makeFirstResponder(nil)
        }
    }
}

@MainActor func mainWindow() -> NSWindow? {
    NSApp.windows.first { AppDelegate.isMainWindow($0) }
}

enum MenuBarPref {
    static let key = "menuBarIcon"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}

/// ⌘Q quits, as everywhere else; closing the window (⌘W, the red button) puts the app away in
/// the menu bar, or quits it when there is no menu bar icon to come back through.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("app UI started (\(AppInfo.version))")
        AgentLink.shared.start()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.windows.first(where: { $0.isVisible })?.makeFirstResponder(nil)
        }
        // The main window closed: drop the web UI and, living in the menu bar from now on,
        // the Dock icon. Both come back as soon as the window is key again.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { n in
            MainActor.assumeIsolated {
                guard AppDelegate.isMainWindow(n.object) else { return }
                AgentLink.shared.uiVisible = false
                if MenuBarPref.enabled { NSApp.setActivationPolicy(.accessory) }
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { n in
            MainActor.assumeIsolated { if AppDelegate.isMainWindow(n.object) { AgentLink.shared.uiVisible = true } }
        }
    }

    static func isMainWindow(_ object: Any?) -> Bool {
        guard let w = object as? NSWindow else { return false }
        return w.canBecomeMain && w.title == "BookmarkSync"
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !MenuBarPref.enabled
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { showMainWindow() } }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AgentSupervisor.shared.stopTemporary(wait: false)
    }
}

struct MenuBarMenu: View {
    @EnvironmentObject var link: AgentLink
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(link.connected ? t("后台服务运行中") : t("后台服务未连接"))
        if let p = link.pending, p.count > 0 { Text(t("待确认 {n} 项", ["n": p.count])) }
        Divider()
        Button(link.busy ?? t("立即同步")) { link.syncNow() }.disabled(link.busy != nil || !link.connected)
        Toggle(t("自动同步"), isOn: Binding(get: { link.settings.autoSync },
                                     set: { link.save(["autoSync": $0]) })).disabled(!link.connected)
        Divider()
        Button(t("打开主窗口")) { MainWindowOpener.open = openWindow; showMainWindow(.sync) }
        Button(t("设置…")) { MainWindowOpener.open = openWindow; showMainWindow(.rules) }
        Divider()
        Button(t("退出 BookmarkSync")) { NSApp.terminate(nil) }
    }
}
