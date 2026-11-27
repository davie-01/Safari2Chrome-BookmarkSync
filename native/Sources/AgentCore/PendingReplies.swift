import Foundation

/// Requests waiting for the agent's reply. Each callback runs exactly once: with the reply,
/// with a timeout error at its deadline, or with the error given to failAll when the
/// connection goes. A reply after the deadline is dropped. Only touched on `queue`.
public final class PendingReplies {
    public typealias Callback = (Result<Any?, AgentError>) -> Void
    private let queue: DispatchQueue
    private var waiting: [Int: (callback: Callback, deadline: DispatchWorkItem)] = [:]

    public init(queue: DispatchQueue) { self.queue = queue }

    public var count: Int { waiting.count }

    public func add(_ id: Int, timeout: TimeInterval, timedOut: AgentError, _ callback: @escaping Callback) {
        let deadline = DispatchWorkItem { [weak self] in self?.resolve(id, .failure(timedOut)) }
        waiting[id] = (callback, deadline)
        queue.asyncAfter(deadline: .now() + timeout, execute: deadline)
    }

    /// False when nothing was waiting for `id` (answered already, or timed out).
    @discardableResult
    public func resolve(_ id: Int, _ result: Result<Any?, AgentError>) -> Bool {
        guard let w = waiting.removeValue(forKey: id) else { return false }
        w.deadline.cancel()
        w.callback(result)
        return true
    }

    public func failAll(_ error: AgentError) {
        let all = waiting
        waiting = [:]
        for (_, w) in all { w.deadline.cancel(); w.callback(.failure(error)) }
    }

    /// How long a UI waits for the agent. Longer than the agent's own limits for the work
    /// behind a request (a browser has 90 s to read and 300 s to write), so those report first.
    public static func timeout(for type: String) -> TimeInterval {
        switch type {
        case "engine.scan", "engine.run", "engine.autoRun": return 600
        case "endpoint.rpc": return 200 // the agent gives the browser 180 s
        case "storage.clean", "state.reset": return 120
        case _ where type.hasPrefix("engine."): return 120
        default: return 30
        }
    }
}
