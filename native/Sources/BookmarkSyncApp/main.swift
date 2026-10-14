import AppKit
import AgentCore

// `open BookmarkSync.app --args install` is how the installer registers the background
// service: SMAppService refuses registrations attributed to Terminal, so the app itself
// must ask. No UI in that case.
let argv = CommandLine.arguments
if argv.contains("install") || argv.contains("uninstall") {
    Log.shared.open(name: "app")
    do {
        let lines = argv.contains("uninstall")
            ? Installer.uninstall()
            : try Installer.install(extensionIDs: [], launchAgent: !argv.contains("--no-launch-agent"))
        for l in lines { print(l) }
        exit(0)
    } catch {
        FileHandle.standardError.write("错误 \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

// launchd starts the background service through the bundle's main executable, so the app
// binary doubles as the agent: `BookmarkSync agent`. No UI in that case.
if argv.contains("agent") {
    Log.shared.open(name: "agent")
    do { try Agent().run() }
    catch {
        Log.error("agent failed: \(error)")
        FileHandle.standardError.write("错误 \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

Log.shared.open(name: "app")
RootApp.main()
