import Foundation
import AppKit

// MARK: - TelemetryClient
//
// Anonymous launcher telemetry — Mac counterpart of the Windows Task 011 design.
//
// Wire model:
//   - Endpoint: https://telemetry.aisuper.win/api/telemetry (Cloudflare Worker + D1).
//   - Auth: none. Server validates `anonymous_id` shape, event name against an allow-list,
//     payload size limits, then INSERTs into D1.
//   - Network: fire-and-forget URLSession dataTask, 8s timeout, ephemeral session,
//     all errors swallowed. Failure is invisible to the UI.
//   - Privacy: every string property + the failure reason runs through `sanitize()`
//     before serialization. PII regex set is kept in lock-step with Windows' Sanitize-TelemetryString.
//   - Default: ON. User toggles in About → settings.json `telemetry_enabled` field.
//   - Anonymous ID: random UUID, persisted at ~/Library/Application Support/HermesLauncher/anonymous_id
//     (generated lazily on first event; never re-generated).

@MainActor
final class TelemetryClient {

    enum Event: String, CaseIterable {
        case launcherOpened          = "launcher_opened"
        case launcherClosed          = "launcher_closed"
        case preflightCheck          = "preflight_check"
        case installResidueCleaned   = "install_residue_cleaned"
        case hermesInstallStarted    = "hermes_install_started"
        case hermesInstallCompleted  = "hermes_install_completed"
        case hermesInstallFailed     = "hermes_install_failed"
        case gatewayStarted          = "gateway_started"
        case gatewayFailed           = "gateway_failed"
        case webuiStarted            = "webui_started"
        case webuiFailed             = "webui_failed"
        case webuiSessionKept5Min    = "webui_session_kept_5min"
        case unexpectedError         = "unexpected_error"
    }

    static let shared = TelemetryClient()

    private let endpoint = URL(string: "https://telemetry.aisuper.win/api/telemetry")!
    private let session: URLSession
    private var firedOnceFlags: Set<Event> = []
    private let launcherVersion: String

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 8
        cfg.allowsCellularAccess = true
        self.session = URLSession(configuration: cfg)
        self.launcherVersion = LauncherSnapshot().version
    }

    // MARK: - Storage

    private static var storageDir: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("HermesLauncher", isDirectory: true)
    }

    private static var anonymousIdFile: URL { storageDir.appendingPathComponent("anonymous_id") }
    private static var settingsFile: URL    { storageDir.appendingPathComponent("settings.json") }

    private static func ensureStorageDir() {
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
    }

    // MARK: - Settings (telemetry_enabled persistence)

    /// True by default; persisted in `~/Library/Application Support/HermesLauncher/settings.json`.
    var isEnabled: Bool {
        get { Self.loadSettings()["telemetry_enabled"] as? Bool ?? true }
        set {
            var s = Self.loadSettings()
            s["telemetry_enabled"] = newValue
            Self.saveSettings(s)
        }
    }

    /// First-run consent banner is **not implemented this round** (kept ON by default with toggle in About).
    /// This flag exists for forward compatibility with the Windows-style consent banner.
    var firstRunConsentShown: Bool {
        get { Self.loadSettings()["first_run_consent_shown"] as? Bool ?? false }
        set {
            var s = Self.loadSettings()
            s["first_run_consent_shown"] = newValue
            Self.saveSettings(s)
        }
    }

    private static func loadSettings() -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsFile),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return dict
    }

    private static func saveSettings(_ dict: [String: Any]) {
        ensureStorageDir()
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) {
            try? data.write(to: settingsFile, options: .atomic)
        }
    }

    // MARK: - Anonymous ID

    private static func loadOrCreateAnonymousId() -> String {
        ensureStorageDir()
        if let raw = try? String(contentsOf: anonymousIdFile, encoding: .utf8) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if isValidAnonymousId(trimmed) { return trimmed }
        }
        let id = UUID().uuidString
        try? id.write(to: anonymousIdFile, atomically: true, encoding: .utf8)
        return id
    }

    private static func isValidAnonymousId(_ s: String) -> Bool {
        guard s.count >= 8 && s.count <= 64 else { return false }
        return s.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil
    }

    // MARK: - Public send API

    func send(_ event: Event, properties: [String: Any] = [:], failureReason: String? = nil) {
        guard isEnabled else { return }

        var props = Self.sanitizeProperties(properties)
        if let reason = failureReason, !reason.isEmpty {
            props["reason"] = Self.sanitize(reason)
        }

        let payload: [String: Any] = [
            "event_name": event.rawValue,
            "anonymous_id": Self.loadOrCreateAnonymousId(),
            "version": launcherVersion,
            "os_version": Self.osVersionString(),
            "memory_category": Self.memoryCategory(),
            "client_timestamp": Int(Date().timeIntervalSince1970),
            "properties": props,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        // Fire-and-forget.
        let task = session.dataTask(with: req) { _, _, _ in }
        task.resume()
    }

    /// Send `event` only if it hasn't already been sent in this session. Used for de-duplicating
    /// transient state events (e.g. `webui_started` may be observed multiple times during refresh).
    func sendOnce(_ event: Event, properties: [String: Any] = [:], failureReason: String? = nil) {
        guard !firedOnceFlags.contains(event) else { return }
        firedOnceFlags.insert(event)
        send(event, properties: properties, failureReason: failureReason)
    }

    /// Reset once-per-session flags (e.g. when a fresh launch is initiated).
    func clearOnceFlags() {
        firedOnceFlags.removeAll()
    }

    // MARK: - Sanitization (mirrors Windows Sanitize-TelemetryString — keep in lock-step)

    static func sanitize(_ raw: String) -> String {
        if raw.isEmpty { return "" }
        var out = raw

        // 0. URL-decode common escapes so the path/user regexes downstream can catch them.
        let decode: [(String, String)] = [
            ("%5C", "\\"), ("%5c", "\\"),
            ("%2F", "/"),  ("%2f", "/"),
            ("%3A", ":"),  ("%3a", ":"),
        ]
        for (a, b) in decode {
            out = out.replacingOccurrences(of: a, with: b)
        }

        // 1. Known sensitive secret patterns.
        out = applyRegex(out, pattern: "(sk-|sk_)[A-Za-z0-9_\\-]+", template: "$1<REDACTED>")
        out = applyRegex(out, pattern: "\\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}", template: "$1_<REDACTED>")
        out = applyRegex(out, pattern: "\\bAIza[0-9A-Za-z_\\-]{30,}", template: "<REDACTED>")
        // key=val style
        for key in ["api[_-]?key", "token", "password", "secret", "Authorization"] {
            out = applyRegex(out, pattern: "(?i)(\(key)\\s*[=:]\\s*)\\S+", template: "$1<REDACTED>")
        }
        out = applyRegex(out, pattern: "(?i)(Bearer\\s+)\\S+", template: "$1<REDACTED>")
        // JSON-style
        out = applyRegex(out,
                        pattern: "(?i)\"(password|token|secret|api[_-]?key)\"\\s*:\\s*\"[^\"]*\"",
                        template: "\"$1\":\"<REDACTED>\"")

        // 2. User paths — POSIX form on macOS.
        out = applyRegex(out, pattern: "(/Users/)[^/\\s]+", template: "$1<USER>")
        out = applyRegex(out, pattern: "(/home/)[^/\\s]+", template: "$1<USER>")
        let home = NSHomeDirectory()
        if home.hasPrefix("/Users/") {
            out = out.replacingOccurrences(of: home, with: "/Users/<USER>")
        }
        // also strip user name from current process env if available
        if let user = ProcessInfo.processInfo.environment["USER"], user.count >= 2 {
            let escaped = NSRegularExpression.escapedPattern(for: user)
            out = applyRegex(out, pattern: "(?i)\(escaped)", template: "<USER>")
        }

        // 3. Email.
        out = applyRegex(out,
                        pattern: "[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}",
                        template: "<EMAIL>")

        // 4. IPv4 + (loose) IPv6.
        out = applyRegex(out, pattern: "\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b", template: "<IP>")
        out = applyRegex(out,
                        pattern: "(?<![A-Za-z0-9])(?:[0-9a-fA-F]{1,4}:){2,}[0-9a-fA-F:]+",
                        template: "<IP>")

        // 5. Truncate.
        if out.count > 500 {
            out = String(out.prefix(500)) + "..."
        }
        return out
    }

    static func sanitizeProperties(_ props: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in props {
            switch v {
            case let b as Bool: out[k] = b
            case let n as Int: out[k] = n
            case let n as Double: out[k] = n
            case let n as Int64: out[k] = n
            case let s as String:
                var clamped = sanitize(s)
                if clamped.count > 256 { clamped = String(clamped.prefix(256)) + "..." }
                out[k] = clamped
            case let arr as [Any]:
                out[k] = arr.map { item -> Any in
                    if let s = item as? String { return sanitize(s) }
                    return item
                }
            default:
                out[k] = sanitize(String(describing: v))
            }
        }
        return out
    }

    private static func applyRegex(_ s: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: template)
    }

    // MARK: - Env metadata

    private static func osVersionString() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private static func memoryCategory() -> String {
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / (1024.0 * 1024.0 * 1024.0)
        switch gb {
        case ..<8:  return "<8GB"
        case ..<16: return "8-16GB"
        case ..<32: return "16-32GB"
        case ..<64: return "32-64GB"
        default:    return ">64GB"
        }
    }
}
