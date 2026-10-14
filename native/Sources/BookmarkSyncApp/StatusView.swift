import SwiftUI
import AgentCore

/// The one window: header (status + sync), a segmented tab bar, the page, a status strip.
/// Every page is sized to fit at the default window size, so no page scrolls.
struct MainWindow: View {
    @EnvironmentObject var link: AgentLink

    var body: some View {
        VStack(spacing: 0) {
            header
            TabBar(selection: $link.tab).id(link.langToken) // rebuild the labels on a language switch
            Divider()
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Color(nsColor: .controlBackgroundColor))
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 520)
        .focusEffectDisabled()
        .onAppear { link.refresh() }
    }

    @ViewBuilder private var page: some View {
        switch link.tab {
        case .sync: SyncPage()
        case .endpoints: EndpointsPage()
        case .rules: RulesPage()
        case .permissions: PermissionsPage()
        case .advanced: AdvancedPage()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "bookmark.square.fill").font(.system(size: 30)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("BookmarkSync").font(.title3.weight(.semibold))
                HStack(spacing: 6) {
                    Circle().fill(dotColor).frame(width: 7, height: 7)
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if link.busy != nil { ProgressView().controlSize(.small) }
            Button(action: { link.syncNow() }) { Text(link.busy ?? t("立即同步")).frame(minWidth: 76) }
                .buttonStyle(.borderedProminent)
                .disabled(link.busy != nil || !link.connected)
                .keyboardShortcut("r")
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 12)
    }

    private var dotColor: Color {
        guard link.connected else { return .orange }
        if let s = link.status, !s.safariReadable || !s.engine { return .orange }
        return .green
    }

    private var subtitle: String {
        if !link.connected { return t("后台服务未运行") }
        guard let s = link.status else { return t("已连接") }
        var parts = [t("版本 {v}", ["v": s.version]), link.resident ? t("常驻同步已开启") : t("仅在 App 打开时同步")]
        if !s.safariReadable { parts.append("⚠️ \(s.accessLabel)") }
        if !s.engine { parts.append(t("⚠️ 同步引擎未加载")) }
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text(statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            FooterButton(title: t("备份"), icon: "clock.arrow.circlepath") { link.reveal("backups") }
            FooterButton(title: t("日志"), icon: "doc.text") { link.reveal("logs") }
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
    }

    private var statusLine: String {
        if let e = link.lastError { return "⚠️ \(e)" }
        if let m = link.lastMessage { return m }
        if let at = link.lastRunAt {
            let today = Calendar.current.isDateInToday(at)
            let f = DateFormatter.ui(today ? "今天 HH:mm" : "M月d日 HH:mm", today ? "'today' HH:mm" : "MMM d, HH:mm")
            return t("上次同步 {when}", ["when": f.string(from: at)])
        }
        return t("还没有同步记录")
    }
}

/// Icon + label segments, like the tabs in System Settings' toolbar.
struct TabBar: View {
    @Binding var selection: AppTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases) { tab in
                Button { withAnimation(.easeOut(duration: 0.12)) { selection = tab } } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon).font(.system(size: 15, weight: .regular))
                        Text(tab.label).font(.caption)
                    }
                    .frame(width: 64, height: 46)
                    .foregroundStyle(selection == tab ? Color.accentColor : Color.secondary)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(selection == tab ? Color.primary.opacity(0.09) : Color.clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(tab.label)
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }
}

struct FooterButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.callout)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
    }
}

// MARK: - 同步

struct SyncPage: View {
    @EnvironmentObject var link: AgentLink

    var body: some View {
        Group {
            if WebBridge.resourceRoot != nil {
                SyncWebView(link: link)
            } else {
                VStack(spacing: 8) {
                    Text(t("界面资源缺失")).font(.headline)
                    Text(t("App 包里没有 web/ui，重新执行 scripts/build-app.sh 即可。"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Rounded card used by the pages, matching the grouped form look.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(nsColor: .textBackgroundColor).opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.primary.opacity(0.08)))
    }
}

/// One endpoint: online dot, name, and (outside the sync page) enable + mode.
struct EndpointRow: View {
    @EnvironmentObject var link: AgentLink
    let ep: EndpointInfo
    let prefs: EndpointPrefs
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(ep.isOnline ? Color.green : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(ep.name)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if compact {
                Text(prefs.isEnabled ? prefs.syncMode.label : t("已停用")).font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("", selection: Binding(
                    get: { prefs.syncMode },
                    set: { link.setEndpoint(ep.id, ["mode": $0.rawValue]) })) {
                    ForEach(SyncMode.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().frame(width: 110)
                .disabled(!prefs.isEnabled)
                .help(prefs.syncMode.help)
                Toggle("", isOn: Binding(
                    get: { prefs.isEnabled },
                    set: { link.setEndpoint(ep.id, ["enabled": $0]) }))
                .labelsHidden()
                .disabled(ep.isSafari && link.endpoints.count < 2)
            }
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        if ep.isSafari { return ep.isOnline ? t("本机 Safari 书签") : t("读取不到 Safari 书签") }
        return ep.isOnline ? t("扩展已连接") : t("离线（浏览器没开或未装扩展）")
    }
}
