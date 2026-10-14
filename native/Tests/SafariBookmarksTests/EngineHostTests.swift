import XCTest
@testable import AgentCore

final class EngineHostTests: XCTestCase {
    func resource(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "js", subdirectory: "Resources"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The whole multi-endpoint scenario (3 endpoints, offline catch-up, URL polyfill) inside JavaScriptCore.
    func testSelfTestScenarioInJavaScriptCore() throws {
        let host = try EngineHost(script: try resource("engine-selftest"), name: "selftest.js") { _, _, r in r(.failure(AgentError("none", "no natives in selftest"))) }
        let exp = expectation(description: "selftest")
        var out = ""
        host.callPromise("BMS_SELFTEST.run", []) { r in
            if case .success(let s) = r { out = s } else if case .failure(let e) = r { out = "failure \(e)" }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 30)
        let obj = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["ok"] as? Bool, true, out)
    }

    /// Promise round trips through native calls (async replies from other threads).
    func testNativeBridge() throws {
        var saved: Any?
        let host = try EngineHost(script: try resource("engine")) { method, params, reply in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                switch method {
                case "settings.load": reply(.success(["autoSync": true, "endpoints": ["safari": ["mode": "send"]]]))
                case "settings.save": saved = (params as? [String: Any])?["settings"]; reply(.success(["ok": true]))
                default: reply(.failure(AgentError("unknownNative", method)))
                }
            }
        }
        let s = try host.handleSync("settings", nil) as? [String: Any]
        XCTAssertEqual(s?["autoSync"] as? Bool, true)
        XCTAssertEqual(s?["autoDeleteMax"] as? Int, 5, "defaults merged")
        _ = try host.handleSync("saveSettings", ["patch": ["endpoints": ["edge": ["mode": "receive"]]]])
        let eps = (saved as? [String: Any])?["endpoints"] as? [String: Any]
        XCTAssertEqual((eps?["safari"] as? [String: Any])?["mode"] as? String, "send")
        XCTAssertEqual((eps?["edge"] as? [String: Any])?["mode"] as? String, "receive")
        XCTAssertEqual((try host.handleSync("canonicalize", ["url": "HTTPS://Example.COM:443/a/../b c"]) as? [String: Any])?["href"] as? String, "https://example.com/b%20c")
        XCTAssertThrowsError(try host.handleSync("nope", nil))
    }
}
