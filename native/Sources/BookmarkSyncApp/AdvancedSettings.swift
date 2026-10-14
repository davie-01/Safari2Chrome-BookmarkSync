import SwiftUI
import AppKit
import AgentCore
import SafariBookmarks

struct AdvancedPage: View {
    @EnvironmentObject var link: AgentLink
    @State private var confirmReset = false
    @State private var confirmClean: (what: String, report: CleanReport)?
    @State private var confirmClearHistory = false
    @State private var uninstallPlan: [Uninstall.Item]?
    @State private var uninstallReport: Uninstall.Report?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // left: where things live and what the interface says
            VStack(spacing: 14) {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        CardTitle(t("Safari 书签文件"))
                        Text(link.settings.safariPath ?? link.status?.safariPath ?? "~/Library/Safari/Bookmarks.plist")
                            .font(.callout.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled).lineLimit(1).truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(t("书签在别处时才需要改，例如从另一台机器拷来的备份。"))
                        HStack {
                            Button(t("选择…")) { choose() }
                            Button(t("恢复默认")) {
                                link.save(["safariPath": ""], note: t("已恢复默认位置，正在重启后台服务"))
                                link.restartAgent()
                            }
                            .disabled((link.settings.safariPath ?? "").isEmpty)
                        }
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        CardTitle(t("界面语言"))
                        SettingRow(t("语言"), note: t("App 和扩展共用这个设置")) {
                            Picker("", selection: Binding(
                                get: { I18n.Choice(rawValue: link.settings.language ?? "system") ?? .system },
                                set: { link.save(["language": $0.rawValue]) })) {
                                ForEach(I18n.Choice.allCases) { Text($0.label).tag($0) }
                            }
                            .labelsHidden().frame(width: 150)
                        }
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        CardTitle(t("同步状态"))
                        SettingRow(t("重置「上次同步到哪」的记录"), note: t("下次扫描按首次同步处理，书签不会被删")) {
                            Button(t("重置…")) { confirmReset = true }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            // right: disk space and the way out
            VStack(spacing: 14) {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        CardTitle(t("存储与清理"))
                        StorageLine(title: t("备份"), stats: link.storage?.backups) { link.reveal("backups") }
                        StorageLine(title: t("日志"), stats: link.storage?.logs) { link.reveal("logs") }
                        Divider()
                        HStack(spacing: 16) {
                            Stepper(value: Binding(get: { link.settings.backupDays ?? 30 }, set: { link.save(["backupDays": $0]) }), in: 1...3650) {
                                Text(t("备份 {n} 天", ["n": link.settings.backupDays ?? 30])).monospacedDigit()
                            }
                            Stepper(value: Binding(get: { link.settings.logDays ?? 30 }, set: { link.save(["logDays": $0]) }), in: 1...3650) {
                                Text(t("日志 {n} 天", ["n": link.settings.logDays ?? 30])).monospacedDigit()
                            }
                        }
                        .help(t("最近 {n} 份备份不论多久都会保留。", ["n": link.settings.backupKeepMin ?? 10]))
                        SettingRow(t("每天自动清理"), note: t("最近 {n} 份备份始终保留", ["n": link.settings.backupKeepMin ?? 10])) {
                            Toggle("", isOn: Binding(get: { link.settings.autoClean ?? true }, set: { link.save(["autoClean": $0]) }))
                                .labelsHidden().toggleStyle(.switch)
                        }
                        Divider()
                        HStack {
                            Button(t("立即清理…")) { askClean("all") }
                            Button(t("清空同步历史…")) { confirmClearHistory = true }
                        }
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        CardTitle(t("卸载"))
                        SettingRow(t("从这台 Mac 上彻底移除"), note: t("后台服务、连接配置、状态、备份、日志全部删除；扩展请自行删除")) {
                            Button(t("卸载…"), role: .destructive) { uninstallPlan = Uninstall.plan() }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 10)
        .disabled(!link.connected)
        .onAppear { link.refreshStorage() }
        .alert(t("清理旧文件？"), isPresented: Binding(get: { confirmClean != nil }, set: { if !$0 { confirmClean = nil } })) {
            Button(t("取消"), role: .cancel) { confirmClean = nil }
            Button(t("清理"), role: .destructive) {
                let what = confirmClean?.what ?? "all"
                confirmClean = nil
                link.clean(what, dryRun: false) { r in
                    guard let r = r else { return }
                    link.note(r.files > 0 ? t("已清理 {n} 个文件，释放 {size}", ["n": r.files, "size": r.sizeText]) : t("没有可清理的文件"))
                }
            }
        } message: {
            Text(confirmClean.map { c in
                c.report.files > 0
                    ? t("将删除 {n} 个文件，释放约 {size}。最近 {keep} 份备份会保留。",
                        ["n": c.report.files, "size": c.report.sizeText, "keep": link.settings.backupKeepMin ?? 10])
                    : t("按当前的保留天数，没有需要清理的文件。")
            } ?? "")
        }
        .alert(t("清空同步历史？"), isPresented: $confirmClearHistory) {
            Button(t("取消"), role: .cancel) {}
            Button(t("清空"), role: .destructive) {
                link.clearHistory { ok in if ok { link.note(t("同步历史已清空")) } }
            }
        } message: {
            Text(t("只清掉「同步历史」里的记录，书签、备份和日志都不受影响。"))
        }
        .alert(t("卸载 BookmarkSync？"), isPresented: Binding(get: { uninstallPlan != nil }, set: { if !$0 { uninstallPlan = nil } })) {
            Button(t("取消"), role: .cancel) { uninstallPlan = nil }
            Button(t("卸载"), role: .destructive) {
                uninstallPlan = nil
                AgentSupervisor.shared.stopTemporary()
                uninstallReport = Uninstall.run(trashApp: true)
            }
        } message: {
            Text(uninstallSummary)
        }
        .alert(t("卸载完成"), isPresented: Binding(get: { uninstallReport != nil }, set: { if !$0 { uninstallReport = nil } })) {
            Button(t("退出")) { AppDelegate.reallyQuit() }
        } message: {
            Text(reportSummary)
        }
        .alert(t("重置同步状态？"), isPresented: $confirmReset) {
            Button(t("取消"), role: .cancel) {}
            Button(t("重置"), role: .destructive) { link.resetState { link.note($0) } }
        } message: {
            Text(t("下一次扫描会把各端合并，不会删除任何书签。"))
        }
    }

    /// The confirmation lists what is actually on disk right now.
    private var uninstallSummary: String {
        guard let plan = uninstallPlan else { return "" }
        let bytes = plan.reduce(0) { $0 + $1.bytes }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        let labels = Array(Set(plan.map(\.label))).sorted().prefix(6).joined(separator: t("、"))
        return t("将删除 {n} 处数据（约 {size}）：{what}。App 会被移到废纸篓，浏览器扩展请自行删除。",
                 ["n": plan.count, "size": size, "what": labels])
    }

    private var reportSummary: String {
        guard let r = uninstallReport else { return "" }
        var lines = [t("已删除 {n} 项，释放 {size}。", ["n": r.removed.count,
                                                "size": ByteCountFormatter.string(fromByteCount: Int64(r.bytes), countStyle: .file)])]
        lines.append(r.appTrashed ? t("App 已移到废纸篓。") : t("App 没能移到废纸篓，请手动删除。"))
        if !r.failed.isEmpty { lines.append(t("{n} 项删除失败：{list}", ["n": r.failed.count, "list": r.failed.map(\.path).joined(separator: t("、"))])) }
        if !r.residue.isEmpty { lines.append(t("仍有残留：{list}", ["list": r.residue.joined(separator: t("、"))])) }
        lines.append(t("最后一步：在浏览器的扩展页面里删除 BookmarkSync 扩展。"))
        return lines.joined(separator: "\n")
    }

    /// Ask the agent what a clean would remove, then confirm with real numbers.
    private func askClean(_ what: String) {
        link.clean(what, dryRun: true) { r in
            guard let r = r else { return }
            confirmClean = (what, r)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = t("选择 Safari 的 Bookmarks.plist")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Safari")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var target = url
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            target = url.appendingPathComponent("Bookmarks.plist")
        }
        do { _ = try SafariStore(url: target).readNormalized() }
        catch {
            link.note(t("这个文件读不出书签：{err}", ["err": "\(error)"]))
            return
        }
        link.save(["safariPath": target.path], note: t("已设置 Safari 书签位置，正在重启后台服务"))
        link.restartAgent()
    }
}

/// t("备份  12 个 · 1.8 MB · 最早 9月1日") with a button that opens the folder.
struct StorageLine: View {
    let title: String
    let stats: DirStats?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(title).fixedSize().frame(minWidth: 34, alignment: .leading)
            Text(detail).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            Spacer(minLength: 4)
            Button(action: action) { Image(systemName: "folder") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(t("在访达中打开"))
        }
    }

    private var detail: String {
        guard let s = stats else { return t("读取中…") }
        var parts = [t("{n} 个", ["n": s.files]), s.sizeText]
        if let d = s.oldestDate {
            let f = DateFormatter.ui("M月d日", "MMM d")
            parts.append(t("最早 {date}", ["date": f.string(from: d)]))
        }
        return parts.joined(separator: " · ")
    }
}
