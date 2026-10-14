import SwiftUI
import WebKit
import AgentCore

/// The sync page is the very UI the browser extension shows (extension/ui), loaded from the
/// app bundle and talking to the agent through this bridge instead of chrome.runtime.
/// One implementation, two hosts.
struct SyncWebView: NSViewRepresentable {
    let link: AgentLink

    func makeCoordinator() -> WebBridge { WebBridge(link: link) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        // file:// blocks ES modules (opaque origin), so serve the UI from our own scheme.
        cfg.setURLSchemeHandler(UIScheme(), forURLScheme: UIScheme.scheme)
        cfg.userContentController.addUserScript(WKUserScript(source: WebBridge.shim, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "bms")
        let web = WKWebView(frame: .zero, configuration: cfg)
        if #available(macOS 13.3, *) { web.isInspectable = true } // Safari's Web Inspector when needed
        web.allowsBackForwardNavigationGestures = false
        context.coordinator.web = web
        if WebBridge.resourceRoot != nil, let url = URL(string: "\(UIScheme.scheme)://ui/index.html") {
            web.load(URLRequest(url: url))
        }
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // The page reads the language itself on load, so a reload is the whole switch.
        if context.coordinator.langToken != link.langToken {
            context.coordinator.langToken = link.langToken
            nsView.reload()
        }
    }
}

/// Serves extension/ui (and the icons next to it) from the app bundle.
final class UIScheme: NSObject, WKURLSchemeHandler {
    static let scheme = "bookmarksync"

    private static let types: [String: String] = [
        "html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8", "json": "application/json", "png": "image/png",
        "svg": "image/svg+xml", "woff2": "font/woff2",
    ]

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let root = WebBridge.resourceRoot, let url = task.request.url else {
            task.didFailWithError(AgentError("notFound", "no ui resources")); return
        }
        // bookmarksync://ui/x -> <ui>/x ; bookmarksync://ui/../icons/32.png -> <ui>/../icons/32.png
        let rel = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        let file = root.appendingPathComponent(rel).standardizedFileURL
        guard file.path.hasPrefix(root.deletingLastPathComponent().path), let data = try? Data(contentsOf: file) else {
            task.didFailWithError(AgentError("notFound", "no such file: \(rel)")); return
        }
        let type = UIScheme.types[file.pathExtension.lowercased()] ?? "application/octet-stream"
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": type,
            "Content-Length": String(data.count),
            "Cache-Control": "no-store",
        ])!
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

@MainActor
final class WebBridge: NSObject, WKScriptMessageHandlerWithReply {
    let link: AgentLink
    weak var web: WKWebView?
    var langToken = 0

    init(link: AgentLink) {
        self.link = link
        super.init()
        link.addEventSink { [weak self] ev in self?.push(ev) }
    }

    /// extension/ui asks for `BookmarkSyncBackend`; give it one backed by this bridge.
    static let shim = """
    (() => {
      globalThis.BookmarkSyncBackend = {
        async call(type, payload) {
          try { return await window.webkit.messageHandlers.bms.postMessage({ type, payload: payload || {} }); }
          catch (e) { return { ok: false, error: { code: 'bridge', message: String((e && e.message) || e) } }; }
        },
        onEvent(fn) { (globalThis.__bmsSinks ||= []).push(fn); },
      };
      const report = (message, extra) => {
        try { window.webkit.messageHandlers.bms.postMessage({ type: '__log', payload: { message: String(message), extra: String(extra || '') } }); } catch (e) {}
      };
      window.addEventListener('error', (e) => report(e.message, (e.error && e.error.stack) || e.filename + ':' + e.lineno));
      window.addEventListener('unhandledrejection', (e) => report('unhandled rejection: ' + ((e.reason && e.reason.message) || e.reason), (e.reason && e.reason.stack) || ''));
      const origError = console.error.bind(console);
      console.error = (...a) => { report(a.map((x) => (x && x.stack) || String(x)).join(' ')); origError(...a); };
      globalThis.__bmsEvent = (m) => { for (const f of (globalThis.__bmsSinks || [])) { try { f(m); } catch (e) {} } };
      const css = '.brand{display:none!important}#btn-settings{display:none!important}' +
                  'header.top{padding-top:6px}[hidden]{display:none!important}';
      const add = () => { const s = document.createElement('style'); s.textContent = css; document.head.appendChild(s); };
      if (document.head) add(); else document.addEventListener('DOMContentLoaded', add);
    })();
    """

    static var resourceRoot: URL? {
        if let o = ProcessInfo.processInfo.environment["BMSYNC_WEB_UI"] { return URL(fileURLWithPath: o, isDirectory: true) }
        if let r = Bundle.main.resourceURL?.appendingPathComponent("web/ui", isDirectory: true),
           FileManager.default.fileExists(atPath: r.appendingPathComponent("index.html").path) { return r }
        // running from the build directory: fall back to the repo copy
        let exe = URL(fileURLWithPath: Installer.executablePath)
        let dev = exe.deletingLastPathComponent().appendingPathComponent("../../../../extension/ui", isDirectory: true).standardizedFileURL
        return FileManager.default.fileExists(atPath: dev.appendingPathComponent("index.html").path) ? dev : nil
    }

    func push(_ event: [String: Any]) {
        guard let web = web,
              let data = try? JSONSerialization.data(withJSONObject: event, options: [.withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("globalThis.__bmsEvent && __bmsEvent(\(json))")
    }

    /// Completion-handler form on purpose: the async variant is not always bridged to
    /// WebKit, and then every call from the page would hang forever.
    nonisolated func userContentController(_ controller: WKUserContentController,
                                           didReceive message: WKScriptMessage,
                                           replyHandler: @escaping (Any?, String?) -> Void) {
        let body = message.body as? [String: Any]
        Task { @MainActor in
            guard let body = body, let type = body["type"] as? String else {
                replyHandler(["ok": false, "error": ["code": "badRequest", "message": "bad message"]], nil)
                return
            }
            let payload = body["payload"] as? [String: Any] ?? [:]
            do {
                let result = try await self.route(type, payload)
                replyHandler(["ok": true, "result": result ?? NSNull()], nil)
            } catch let e as AgentError {
                replyHandler(["ok": false, "error": ["code": e.code, "message": e.message]], nil)
            } catch {
                replyHandler(["ok": false, "error": ["code": "error", "message": error.localizedDescription]], nil)
            }
        }
    }

    /// Same request names the extension's background.js answers.
    private func route(_ type: String, _ payload: [String: Any]) async throws -> Any? {
        switch type {
        case "__log":
            Log.warn("webui: \(payload["message"] ?? "") \(payload["extra"] ?? "")")
            return nil
        case "status":
            var out: [String: Any] = ["endpointId": "app", "endpoint": ["id": "app", "kind": "app", "name": "BookmarkSync"]]
            do { out["agent"] = try await link.call("hello") }
            catch let e as AgentError { out["agentError"] = ["code": e.code, "message": e.message]; return out }
            out["settings"] = (try? await link.engineCall("settings")) ?? [:]
            if let p = try? await link.engineCall("pending") { out["pending"] = p }
            link.refresh()
            return out
        case "storage":
            return try await link.call("storage.stats")
        case "clean":
            let r = try await link.call("storage.clean", ["what": payload["what"] ?? "all", "dryRun": payload["dryRun"] ?? false])
            link.refreshStorage()
            return r
        case "clearHistory":
            return try await link.engineCall("clearHistory")
        case "scan", "preview", "run", "autoRun", "settings", "saveSettings", "history", "pending", "lastRun":
            let r = try await link.engineCall(type, payload)
            if type == "run" || type == "saveSettings" { link.refresh() }
            return r
        case "resetState":
            let r = try await link.call("state.reset")
            link.refresh()
            return r
        case "reveal":
            return try await link.call("reveal", ["what": payload["what"] ?? "backups"])
        case "backups":
            return try await link.call("backups.list")
        case "restoreOrder":
            return try await link.call("endpoint.rpc", ["method": "restoreOrder", "params": payload])
        default:
            throw AgentError("unknownType", t("界面请求了未知的操作 {what}", ["what": type]))
        }
    }
}
