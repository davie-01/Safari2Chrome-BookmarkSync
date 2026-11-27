import SwiftUI
import AgentCore

// MARK: - 端

struct EndpointsPage: View {
    @EnvironmentObject var link: AgentLink
    @State private var forgetting: OfflineEndpoint?

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
            if !link.offlineEndpoints.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        CardTitle(t("已离线的端"))
                        Text(t("同步记录里有、现在没有连上的浏览器。浏览器只是关着的话，打开后会自动回来；扩展已删除或换了 ID 的，可以移除。"))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(link.offlineEndpoints) { ep in
                            Divider()
                            HStack(spacing: 10) {
                                Circle().fill(Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(ep.name)
                                    Text(offlineDetail(ep)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(t("移除…")) { forgetting = ep }
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .disabled(!link.connected && !link.switchingAgent)
        .alert(t("移除「{name}」？", ["name": forgetting?.name ?? ""]),
               isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
            Button(t("取消"), role: .cancel) { forgetting = nil }
            Button(t("移除"), role: .destructive) {
                if let ep = forgetting { link.forgetEndpoint(ep) }
                forgetting = nil
            }
        } message: {
            Text(t("只删除这一端的同步记录和设置，不会动任何书签。以后它再连上，会按新加入的一端处理：相同的书签自动配对，其余合并，不会删除。"))
        }
    }

    /// When it last synced, and enough of its ID to tell two of the same browser apart.
    private func offlineDetail(_ ep: OfflineEndpoint) -> String {
        let id = t("ID {id}…", ["id": String(ep.id.prefix(11))])
        guard let ms = ep.lastSyncAt ?? ep.firstSeenAt else { return id }
        let f = DateFormatter.ui("M月d日 HH:mm", "MMM d, HH:mm")
        let when = f.string(from: Date(timeIntervalSince1970: ms / 1000))
        return (ep.lastSyncAt != nil ? t("上次同步 {when}", ["when": when]) : t("首次出现 {when}", ["when": when])) + " · " + id
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
                        SettingRow(t("常驻后台同步"),
                                   note: link.residentNote?.text ?? (link.resident ? t("登录时自动启动，浏览器没开也同步") : t("只在 App 打开时同步，退出后不留进程")),
                                   warning: link.residentNote?.warning ?? false) {
                            HStack(spacing: 8) {
                                if link.switchingAgent && link.operation == .switchResident { ProgressView().controlSize(.small) }
                                Toggle("", isOn: Binding(get: { link.residentTarget ?? link.resident }, set: { link.setResident($0) }))
                                    .labelsHidden()
                                    .disabled(link.switchingAgent)
                            }
                        }
                        ResidentSwitchActions()
                        Divider()
                        SettingRow(t("显示菜单栏图标"), note: t("关掉后，关闭窗口就会退出 App")) {
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
        .disabled(!link.connected && !link.switchingAgent)
    }

    private func bind(_ key: KeyPath<EngineSettings, Bool>, _ name: String) -> Binding<Bool> {
        Binding(get: { link.settings[keyPath: key] }, set: { link.save([name: $0]) })
    }
}

/// What can be done about a failed switch of the resident service, right under it.
struct ResidentSwitchActions: View {
    @EnvironmentObject var link: AgentLink

    var body: some View {
        if link.operation == .switchResident, case .failed(_, let needsApproval) = link.residentSwitch {
            HStack {
                Spacer()
                if needsApproval { Button(t("打开登录项设置")) { AgentLink.openLoginItems() } }
                else { Button(t("重试")) { link.retryResidentSwitch() } }
            }
        }
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
    var noteIsWarning = false
    @ViewBuilder var control: Control

    init(_ title: String, note: String? = nil, warning: Bool = false, @ViewBuilder control: () -> Control) {
        self.title = title
        self.note = note
        self.noteIsWarning = warning
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let n = note {
                    Text(n).font(.caption).foregroundStyle(noteIsWarning ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
    }
}
