import SwiftUI
import AgentCore

// MARK: - 端

struct EndpointsPage: View {
    @EnvironmentObject var link: AgentLink

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("每个浏览器的用户配置算一个独立的端。停用的端不参与同步，重新启用后会自动补上错过的改动。"))
                .font(.callout).foregroundStyle(.secondary)
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(link.endpoints) { ep in
                        EndpointRow(ep: ep, prefs: link.settings.prefs(ep.id))
                        if ep.id != link.endpoints.last?.id { Divider() }
                    }
                    if link.endpoints.isEmpty {
                        Text(t("还没有端连上来")).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Text(t("模式：双向 · 只接收（别人的改动写进来）· 只发送（只把自己的改动传出去）"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(t("刷新")) { link.refresh() }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .disabled(!link.connected)
    }
}

// MARK: - 规则

/// Two columns of cards so every rule fits at the default window size (no scrolling).
struct RulesPage: View {
    @EnvironmentObject var link: AgentLink
    @AppStorage(MenuBarPref.key) private var menuBar = true

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // left: when syncing happens on its own
            VStack(spacing: 14) {
                Card {
                    VStack(spacing: 8) {
                        CardTitle(t("自动同步"))
                        SettingRow(t("检测到改动后自动同步")) {
                            Toggle("", isOn: bind(\.autoSync, "autoSync")).labelsHidden()
                        }
                        Divider()
                        SettingRow(t("等待时间"), note: t("改动停下这么久之后再执行")) {
                            Stepper(value: Binding(get: { link.settings.autoDelay }, set: { link.save(["autoDelay": $0]) }), in: 1...120) {
                                Text(t("{n} 秒", ["n": link.settings.autoDelay])).monospacedDigit()
                            }
                            .disabled(!link.settings.autoSync)
                        }
                        Divider()
                        SettingRow(t("自动同步也执行删除"), note: t("冲突和大范围重排永远等你确认")) {
                            Toggle("", isOn: bind(\.autoDelete, "autoDelete")).labelsHidden()
                                .disabled(!link.settings.autoSync)
                        }
                        Divider()
                        SettingRow(t("单次最多删除"), note: t("超过上限的删除留到界面里确认")) {
                            Stepper(value: Binding(get: { link.settings.autoDeleteMax }, set: { link.save(["autoDeleteMax": $0]) }), in: 1...100) {
                                Text(t("{n} 项", ["n": link.settings.autoDeleteMax])).monospacedDigit()
                            }
                            .disabled(!link.settings.autoSync || !link.settings.autoDelete)
                        }
                    }
                }
                Card {
                    VStack(spacing: 8) {
                        CardTitle("Safari")
                        SettingRow(t("Safari 开着时也写入"), note: t("关闭后等 Safari 退出再写")) {
                            Toggle("", isOn: bind(\.safariWhileRunning, "safariWhileRunning")).labelsHidden()
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            // right: where it runs, and who decides the order
            VStack(spacing: 14) {
                Card {
                    VStack(spacing: 8) {
                        CardTitle(t("后台"))
                        SettingRow(t("常驻后台同步"), note: link.resident ? t("登录时自动启动，浏览器没开也同步") : t("只在 App 打开时同步，退出后不留进程")) {
                            Toggle("", isOn: Binding(get: { link.resident }, set: { link.setResident($0) })).labelsHidden()
                        }
                        Divider()
                        SettingRow(t("显示菜单栏图标"), note: t("关掉后 ⌘Q 会变成真正退出")) {
                            Toggle("", isOn: $menuBar).labelsHidden()
                        }
                    }
                }
                Card {
                    VStack(spacing: 8) {
                        CardTitle(t("顺序"))
                        SettingRow(t("同步书签顺序")) {
                            Toggle("", isOn: bind(\.syncOrder, "syncOrder")).labelsHidden()
                        }
                        Divider()
                        SettingRow(t("顺序以哪一端为准"), note: t("多端都改了顺序时，以这一端为准")) {
                            Picker("", selection: Binding(
                                get: { link.settings.orderMaster ?? "" },
                                set: { link.save(["orderMaster": $0.isEmpty ? NSNull() : $0]) })) {
                                Text(t("自动（第一个 Chrome）")).tag("")
                                ForEach(link.endpoints) { Text($0.name).tag($0.id) }
                            }
                            .labelsHidden().frame(width: 150)
                            .disabled(!link.settings.syncOrder)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 10)
        .toggleStyle(.switch)
        .disabled(!link.connected)
    }

    private func bind(_ key: KeyPath<EngineSettings, Bool>, _ name: String) -> Binding<Bool> {
        Binding(get: { link.settings[keyPath: key] }, set: { link.save([name: $0]) })
    }
}

struct CardTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Label (+ small note) on the left, one control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    var note: String?
    @ViewBuilder var control: Control

    init(_ title: String, note: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.note = note
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let n = note {
                    Text(n).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
    }
}
