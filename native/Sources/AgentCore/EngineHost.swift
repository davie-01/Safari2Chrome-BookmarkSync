import Foundation
import JavaScriptCore

/// Runs the bundled sync engine (extension/engine → Resources/engine.js) in JavaScriptCore.
///
/// Threading: the JSContext is only ever touched on `queue`. Native calls the engine makes
/// (`__nativeCall`) are answered asynchronously by `native`; their completion hops back onto
/// `queue` to resolve the JS promise. JavaScriptCore drains the microtask queue when each
/// API call returns, so promise chains advance on every resolve.
public final class EngineHost {
    public typealias Reply = (Result<Any?, AgentError>) -> Void
    /// (method, params, reply). Must call `reply` exactly once, from any thread.
    public typealias Native = (String, Any?, @escaping Reply) -> Void

    public let queue = DispatchQueue(label: "bmsync.engine")
    private var context: JSContext!
    private let native: Native

    public init(script: String, name: String = "engine.js", native: @escaping Native) throws {
        self.native = native
        var loadError: String?
        queue.sync {
            let ctx = JSContext()!
            ctx.name = "BookmarkSync engine"
            ctx.exceptionHandler = { _, exc in
                Log.error("engine exception: \(exc?.toString() ?? "?")")
            }
            let uuid: @convention(block) () -> String = { UUID().uuidString }
            ctx.setObject(uuid, forKeyedSubscript: "__uuid" as NSString)
            let log: @convention(block) (String) -> Void = { Log.info("engine: \($0.prefix(500))") }
            let console = JSValue(newObjectIn: ctx)!
            console.setObject(log, forKeyedSubscript: "log" as NSString)
            console.setObject(log, forKeyedSubscript: "warn" as NSString)
            console.setObject(log, forKeyedSubscript: "error" as NSString)
            ctx.setObject(console, forKeyedSubscript: "console" as NSString)

            let call: @convention(block) (String, String, JSValue, JSValue) -> Void = { [weak self] method, paramsJSON, resolve, reject in
                guard let self = self else { return }
                let params = paramsJSON.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
                self.native(method, params is NSNull ? nil : params) { result in
                    self.queue.async {
                        switch result {
                        case .success(let v):
                            let json = (try? JSONSerialization.data(withJSONObject: v ?? NSNull(), options: [.fragmentsAllowed, .withoutEscapingSlashes]))
                                .flatMap { String(data: $0, encoding: .utf8) } ?? "null"
                            resolve.call(withArguments: [json])
                        case .failure(let e):
                            reject.call(withArguments: [e.code, e.message])
                        }
                    }
                }
            }
            ctx.setObject(call, forKeyedSubscript: "__nativeCall" as NSString)

            ctx.evaluateScript(script, withSourceURL: URL(string: "bmsync://\(name)"))
            if let exc = ctx.exception { loadError = exc.toString(); ctx.exception = nil }
            self.context = ctx
        }
        if let e = loadError { throw AgentError("engineLoad", "engine failed to load: \(e)") }
    }

    /// Locates engine.js: $BMSYNC_ENGINE, app bundle Resources, or next to the executable.
    public static func bundledScript() throws -> String {
        var candidates: [URL] = []
        if let o = ProcessInfo.processInfo.environment["BMSYNC_ENGINE"] { candidates.append(URL(fileURLWithPath: o)) }
        if let r = Bundle.main.url(forResource: "engine", withExtension: "js") { candidates.append(r) }
        let exe = URL(fileURLWithPath: Installer.executablePath)
        candidates.append(exe.deletingLastPathComponent().appendingPathComponent("../Resources/engine.js").standardizedFileURL)
        candidates.append(exe.deletingLastPathComponent().appendingPathComponent("engine.js"))
        for c in candidates {
            if let s = try? String(contentsOf: c, encoding: .utf8) { return s }
        }
        throw AgentError("engineMissing", "engine.js not found (looked in \(candidates.map(\.path).joined(separator: ", ")))")
    }

    /// Calls a global function path like "BMS.handle" with string args; the function returns a Promise<string>.
    public func callPromise(_ path: String, _ args: [String], completion: @escaping (Result<String, AgentError>) -> Void) {
        queue.async {
            guard let ctx = self.context else { completion(.failure(AgentError("engine", "no context"))); return }
            var fn: JSValue = ctx.globalObject
            for part in path.split(separator: ".") { fn = fn.objectForKeyedSubscript(String(part)) }
            guard !fn.isUndefined else { completion(.failure(AgentError("engine", "\(path) is undefined"))); return }
            var done = false
            let finish: (Result<String, AgentError>) -> Void = { r in
                if done { return }
                done = true
                completion(r)
            }
            let onOk: @convention(block) (JSValue) -> Void = { v in finish(.success(v.isString ? v.toString() : "null")) }
            let onErr: @convention(block) (JSValue) -> Void = { e in
                let code = e.objectForKeyedSubscript("code")
                let msg = e.objectForKeyedSubscript("message")
                finish(.failure(AgentError(code?.isString == true ? code!.toString() : "engineError",
                                           msg?.isString == true ? msg!.toString() : e.toString())))
            }
            let promise = fn.call(withArguments: args)
            if let exc = ctx.exception {
                ctx.exception = nil
                finish(.failure(AgentError("engineError", exc.toString())))
                return
            }
            guard let p = promise, p.hasProperty("then") else {
                finish(.success(promise?.toString() ?? "null"))
                return
            }
            p.invokeMethod("then", withArguments: [JSValue(object: onOk, in: ctx)!, JSValue(object: onErr, in: ctx)!])
        }
    }

    /// BMS.handle(method, params) -> JSON-decoded result.
    public func handle(_ method: String, _ params: Any?, completion: @escaping (Result<Any?, AgentError>) -> Void) {
        let json = (try? JSONSerialization.data(withJSONObject: params ?? [:], options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        callPromise("BMS.handle", [method, json]) { r in
            completion(r.map { s in s.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) } })
        }
    }

    /// Blocking variant for callers that are not on `queue` (tests, CLI).
    public func handleSync(_ method: String, _ params: Any?, timeout: TimeInterval = 120) throws -> Any? {
        let sem = DispatchSemaphore(value: 0)
        var out: Result<Any?, AgentError> = .failure(AgentError("timeout", "engine call \(method) timed out"))
        handle(method, params) { r in out = r; sem.signal() }
        if sem.wait(timeout: .now() + timeout) == .timedOut { throw AgentError("timeout", "engine call \(method) timed out") }
        return try out.get()
    }
}
