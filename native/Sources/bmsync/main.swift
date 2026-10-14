import Foundation
import AgentCore
import SafariBookmarks

let args = CommandLine.arguments

func usage() -> Never {
    print("""
    bmsync \(AppInfo.version) — Safari ↔ Chrome 书签同步（本机 agent / native host）

    用法:
      bmsync install [--extension-id ID ...] [--no-launch-agent]   注册 LaunchAgent 与 Chrome native host
      bmsync uninstall                                            移除注册（保留状态与备份）
      bmsync status                                               检查权限、agent、Safari 状态
      bmsync dump [--file PATH] [--stats]                         输出规范化的 Safari 书签 JSON（只读）
      bmsync apply --file COPY.plist --ops OPS.json               对一份 plist 副本执行操作（测试用）
      bmsync agent                                                以 agent 方式运行（由 LaunchAgent 调用）
      bmsync version
    """)
    exit(2)
}

func value(after flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func values(after flag: String) -> [String] {
    var out: [String] = []
    var i = 0
    while i < args.count {
        if args[i] == flag, i + 1 < args.count { out.append(args[i + 1]); i += 2 } else { i += 1 }
    }
    return out
}

func printJSON(_ v: Any) {
    if let d = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]),
       let s = String(data: d, encoding: .utf8) { print(s) }
}

// Chrome launches the native host with the calling origin as first argument.
if args.count >= 2, args[1].hasPrefix("chrome-extension://") {
    NativeHost.run(origin: args[1])
}

guard args.count >= 2 else { usage() }

do {
    switch args[1] {
    case "agent":
        Log.shared.open(name: "agent")
        try Agent().run()

    case "install":
        var ids = values(after: "--extension-id")
        if ids.isEmpty { ids = [Installer.defaultExtensionID] }
        for line in try Installer.install(extensionIDs: ids, launchAgent: !args.contains("--no-launch-agent")) { print(line) }

    case "uninstall":
        for line in Installer.uninstall() { print(line) }

    case "status":
        let store = SafariStore()
        let access = store.access()
        print("版本:            \(AppInfo.version)")
        print("可执行文件:      \(Installer.executablePath)")
        print("Safari 书签:     \(store.url.path)")
        print("本进程读取权限:  \(access.rawValue)\(access == .noFullDiskAccess ? "（终端里运行时，这反映的是终端的权限，不是 agent 的）" : "")")
        print("Safari 运行中:   \(SafariStore.safariRunning() ? "是" : "否")")
        print("后台服务注册:    \(Installer.agentStatus)\(FileManager.default.fileExists(atPath: Paths.launchAgentPlist.path) ? "（另有旧版 LaunchAgent，重新 install 会清理）" : "")")
        if let fd = connectUnix(Paths.socket.path) {
            let req = try JSON.data(["id": 1, "type": "hello"]) + Data([0x0A])
            _ = writeAll(fd, req)
            if let line = LineReader(fd: fd).next(), let resp = try? JSON.object(line), let r = resp["result"] as? [String: Any] {
                print("Agent:           运行中 pid=\(r["agentPid"] ?? "?") 版本=\(r["version"] ?? "?")")
                print("Agent 读取权限:  \(r["safariAccess"] ?? "?")\((r["safariAccess"] as? String) == "noFullDiskAccess" ? "  ← 需要给 BookmarkSync.app 完全磁盘访问权限，然后执行 launchctl kickstart -k gui/$(id -u)/\(AppInfo.embeddedAgentLabel)" : "")")
            } else { print("Agent:           已连接但无响应") }
            close(fd)
        } else {
            print("Agent:           未运行（\(Paths.socket.path)）")
        }
        let manifest = Paths.home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts/\(AppInfo.nativeHostName).json")
        print("Chrome 清单:     \(FileManager.default.fileExists(atPath: manifest.path) ? manifest.path : "未安装")")

    case "dump":
        let store = value(after: "--file").map { SafariStore(url: URL(fileURLWithPath: $0)) } ?? SafariStore()
        let r = try store.readNormalized()
        if args.contains("--stats") {
            printJSON(try JSON.value(r.stats))
        } else {
            printJSON(try JSON.value(r))
        }

    case "apply":
        guard let file = value(after: "--file"), let opsPath = value(after: "--ops") else { usage() }
        let store = SafariStore(url: URL(fileURLWithPath: file))
        if store.isRealSafariFile && !args.contains("--real") {
            print("拒绝：这是真实的 Safari 书签文件。测试请用副本；确需写入请加 --real（默认仍要求 Safari 已退出，--allow-running 允许运行时写入）。")
            exit(1)
        }
        let ops = try JSONDecoder().decode([SafariOp].self, from: Data(contentsOf: URL(fileURLWithPath: opsPath)))
        var opts = SafariStore.ApplyOptions()
        opts.allowWhileSafariRunning = args.contains("--allow-running")
        let r = try store.apply(ops, options: opts)
        print("applied \(r.applied) ops; fingerprint \(r.fingerprint.prefix(12)); backup \(r.backup ?? "-")")

    case "version", "--version", "-v":
        print(AppInfo.version)

    default:
        usage()
    }
} catch let e as AgentError {
    FileHandle.standardError.write("错误 [\(e.code)] \(e.message)\n".data(using: .utf8)!)
    exit(1)
} catch {
    FileHandle.standardError.write("错误 \(error)\n".data(using: .utf8)!)
    exit(1)
}
