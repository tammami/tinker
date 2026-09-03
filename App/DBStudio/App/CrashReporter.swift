import Foundation
import Logging
import AppKit
import os

/// Collects diagnostics locally, and only with the user's consent.
///
/// SPEC §16 Phase 7 asks for opt-in crash reporting with local logs and no third party.
/// Nothing here leaves the machine: reports are written under Application Support and the
/// user opens the folder themselves.
@MainActor
public final class CrashReporter {
    public static let optInSettingKey = "diagnostics.collectCrashReports"

    private let environment: AppEnvironment
    private var isEnabled = false

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    /// Where reports are written.
    public nonisolated static var reportsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("DBStudio/Diagnostics", isDirectory: true)
    }

    /// Reads the user's choice and installs the handlers if they said yes.
    public func start() async {
        isEnabled = await environment.setting(Self.optInSettingKey, default: false)
        guard isEnabled else { return }
        installHandlers()
    }

    public func setEnabled(_ enabled: Bool) async {
        isEnabled = enabled
        await environment.setSetting(enabled, for: Self.optInSettingKey)
        if enabled { installHandlers() }
    }

    /// Catches the two failures a Swift app can still report from inside itself.
    ///
    /// A hard crash is caught by the system's own reporter; these handlers cover the cases
    /// where the process is still alive enough to write a file.
    private func installHandlers() {
        NSSetUncaughtExceptionHandler { exception in
            CrashReporter.write(
                title: "Uncaught exception",
                body: """
                    name: \(exception.name.rawValue)
                    reason: \(exception.reason ?? "none")

                    \(exception.callStackSymbols.joined(separator: "\n"))
                    """
            )
        }
    }

    /// Writes one report. Deliberately free of user data: no SQL, no values, no
    /// connection details beyond the app's own version (SPEC §18).
    nonisolated static func write(title: String, body: String) {
        let directory = reportsDirectory
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let report = """
            DBStudio \(version) (\(build))
            macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
            \(stamp)

            \(title)

            \(body)
            """
        try? report.write(
            to: directory.appendingPathComponent("crash-\(stamp).txt"),
            atomically: true, encoding: .utf8
        )
    }

    /// Reports written so far, newest first.
    public nonisolated static func existingReports() -> [URL] {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: reportsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
        )
        return (contents ?? [])
            .filter { $0.pathExtension == "txt" }
            .sorted { left, right in
                let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return leftDate > rightDate
            }
    }

    public nonisolated static func revealReportsInFinder() {
        try? FileManager.default.createDirectory(
            at: reportsDirectory, withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(reportsDirectory)
    }

    public nonisolated static func deleteAllReports() {
        for url in existingReports() { try? FileManager.default.removeItem(at: url) }
    }
}
