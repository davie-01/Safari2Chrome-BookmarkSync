import Foundation
import AgentCore

/// Chinese is the source language: every UI string is written in Chinese and looked up in
/// `en.json` when the interface runs in English. The same file backs the web UI, so both
/// hosts say the same thing (extension/ui/en.json → Resources/web/ui/en.json).
///
/// `t("备份保留 {n} 天", ["n": 30])` — placeholders are filled after the lookup.
enum I18n {
    enum Choice: String, CaseIterable, Identifiable {
        case system, zh, en
        var id: String { rawValue }
        var label: String {
            switch self {
            case .system: return t("跟随系统")
            case .zh: return "简体中文"
            case .en: return "English"
            }
        }
    }

    private(set) static var lang = "zh"
    private static var dict: [String: String] = [:]

    static var isEnglish: Bool { lang == "en" }
    static var locale: Locale { Locale(identifier: isEnglish ? "en_US" : "zh_Hans") }

    /// "system" (or nil) follows the Mac's language.
    static func systemLang() -> String {
        let pref = Locale.preferredLanguages.first?.lowercased() ?? "zh"
        return pref.hasPrefix("zh") ? "zh" : "en"
    }

    @discardableResult
    static func use(_ setting: String?) -> String {
        let want = (setting == nil || setting == "system" || setting!.isEmpty) ? systemLang() : setting!
        guard want != lang else { return lang }
        lang = want
        if want == "en" && dict.isEmpty { dict = loadDict() }
        return lang
    }

    static func lookup(_ zh: String) -> String {
        guard isEnglish, let s = dict[zh], !s.isEmpty else { return zh }
        return s
    }

    private static func loadDict() -> [String: String] {
        var candidates: [URL] = []
        if let o = ProcessInfo.processInfo.environment["BMSYNC_WEB_UI"] {
            candidates.append(URL(fileURLWithPath: o, isDirectory: true).appendingPathComponent("en.json"))
        }
        if let r = Bundle.main.resourceURL?.appendingPathComponent("web/ui/en.json") { candidates.append(r) }
        // running from the build directory: the repo copy next to the UI
        let exe = URL(fileURLWithPath: Installer.executablePath)
        candidates.append(exe.deletingLastPathComponent()
            .appendingPathComponent("../../../../extension/ui/en.json").standardizedFileURL)
        for c in candidates {
            if let d = try? Data(contentsOf: c),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: String] { return o }
        }
        Log.warn("en.json not found; interface stays in Chinese")
        return [:]
    }
}

/// Translates and fills `{placeholders}`.
func t(_ zh: String, _ vars: [String: Any] = [:]) -> String {
    var s = I18n.lookup(zh)
    for (k, v) in vars { s = s.replacingOccurrences(of: "{\(k)}", with: "\(v)") }
    return s
}

extension DateFormatter {
    /// A formatter in the interface's language.
    static func ui(_ zhFormat: String, _ enFormat: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = I18n.locale
        f.dateFormat = I18n.isEnglish ? enFormat : zhFormat
        return f
    }
}
