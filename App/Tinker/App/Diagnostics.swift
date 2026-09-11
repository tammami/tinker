import DBCore
import Foundation

/// The text behind Settings › Diagnostics › Copy Diagnostics: what a bug report needs
/// and nothing a bug report must not carry. Versions, the engines configured, the
/// diagnostics setting, and the last log records — no host names, no SQL, no values,
/// no credentials (SPEC §18 rule 4).
@MainActor
enum Diagnostics {
    static func summary(environment: AppEnvironment) -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        var engines: [String: Int] = [:]
        for connection in environment.connections { engines[connection.dialect.displayName, default: 0] += 1 }
        let engineList =
            engines.isEmpty
            ? "none configured"
            : engines.keys.sorted().map { "\($0) ×\(engines[$0] ?? 0)" }.joined(separator: ", ")
        var lines = [
            "\(Product.name) \(version) (\(build))",
            "macOS \(system)",
            "Connections: \(engineList)",
            "Log subsystem: \(AppLogging.subsystem) (Console, or `log show --predicate 'subsystem == \"\(AppLogging.subsystem)\"' --last 1h`)",
            "",
            "Recent log records:",
        ]
        let records = AppLogging.recentRecords()
        lines.append(contentsOf: records.isEmpty ? ["(none this session)"] : records)
        return lines.joined(separator: "\n")
    }
}
