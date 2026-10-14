import SwiftUI
import AppKit
import AgentCore
import UserNotifications

/// One row per permission the app needs, each with what it is for and a button that opens
/// the right place in System Settings.
struct PermissionsPage: View {
    @EnvironmentObject var link: AgentLink
    @State private var notifications = t("检查中…")
    @State private var notificationsOK = false

    var body: some View {
        Form {
            Section {
                PermissionRow(
                    title: t("完全磁盘访问权限"),
                    ok: link.status?.safariReadable ?? false,
                    detail: detailFullDisk,
                    action: (t("打开系统设置"), { open("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") }))
                Text(t("macOS 把 Safari 的书签文件列为受保护数据。把 BookmarkSync.app 加进这一项并勾选，然后点下面的「重启后台服务」。"))
                    .font(.caption).foregroundStyle(.secondary)
                Button(t("重启后台服务")) { link.restartAgent() }
            }
            Section {
                PermissionRow(
                    title: t("后台运行"),
                    ok: link.resident,
                    detail: link.resident ? t("已注册，登录时自动启动") : t("未注册：只有 BookmarkSync 打开时才同步"),
                    action: (t("打开登录项设置"), { open("x-apple.systempreferences:com.apple.LoginItems-Settings.extension") }))
                PermissionRow(
                    title: t("浏览器扩展连接"),
                    ok: link.endpoints.contains { !$0.isSafari && $0.isOnline },
                    detail: extensionDetail,
                    action: (t("刷新"), { link.refresh() }))
                PermissionRow(
                    title: t("通知"),
                    ok: notificationsOK,
                    detail: notifications,
                    action: (t("请求授权"), { requestNotifications() }))
                Text(t("通知用于同步失败或有项目需要确认时提醒你，可以不授权。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { link.refresh(); checkNotifications() }
    }

    private var detailFullDisk: String {
        guard let s = link.status else { return t("后台服务未运行，无法检查") }
        return s.safariReadable ? t("可以读写 {path}", ["path": s.safariPath]) : s.accessLabel
    }

    private var extensionDetail: String {
        let online = link.endpoints.filter { !$0.isSafari && $0.isOnline }
        if online.isEmpty { return t("没有浏览器扩展连上来（浏览器没开，或还没安装扩展）") }
        return online.map(\.name).joined(separator: "、") + t(" 已连接")
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    private func checkNotifications() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            DispatchQueue.main.async {
                switch s.authorizationStatus {
                case .authorized, .provisional: notifications = t("已授权"); notificationsOK = true
                case .denied: notifications = t("已拒绝（可在「系统设置 → 通知」里打开）"); notificationsOK = false
                default: notifications = t("尚未请求"); notificationsOK = false
                }
            }
        }
    }

    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, err in
            DispatchQueue.main.async {
                if let err = err { notifications = t("无法请求：{msg}", ["msg": err.localizedDescription]) }
                checkNotifications()
            }
        }
    }
}

struct PermissionRow: View {
    let title: String
    let ok: Bool
    let detail: String
    let action: (String, () -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(ok ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let a = action { Button(a.0) { a.1() } }
        }
        .padding(.vertical, 2)
    }
}
