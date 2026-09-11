import Foundation
import Logging
import os

/// Where the app's swift-log output goes.
///
/// swift-log's default handler prints to standard output, which a Finder-launched app
/// discards: nothing any package logged ever reached a place a person could read. The
/// handler installed here writes each record to the unified log under the app's
/// subsystem — the swift-log label is the category, so `log show --predicate
/// 'subsystem == "com.thinkfree.Tinker"'` and Console show them — and keeps the last
/// few hundred records in memory for Settings › Diagnostics › Copy Diagnostics.
///
/// Nothing above `.debug` carries SQL text, values or credentials (SPEC §18 rule 4); the
/// drivers log those at `.debug` only, and the memory buffer keeps `.info` and above.
enum AppLogging {
    static let subsystem = "com.thinkfree.Tinker"

    /// Installs the handler. Once per process; a second call is ignored.
    static func bootstrap() {
        guard RecentRecords.shared.markBootstrapped() else { return }
        LoggingSystem.bootstrap { label in
            var handler = OSLogHandler(label: label)
            handler.logLevel = .info
            return handler
        }
    }

    /// The last records logged at `.info` and above, oldest first, for a diagnostics copy.
    static func recentRecords() -> [String] { RecentRecords.shared.lines() }

    /// A bounded, lock-protected buffer of formatted records.
    final class RecentRecords: @unchecked Sendable {
        static let shared = RecentRecords()
        static let capacity = 400

        private let lock = NSLock()
        private var buffer: [String] = []
        private var bootstrapped = false

        func append(_ line: String) {
            lock.lock()
            defer { lock.unlock() }
            buffer.append(line)
            if buffer.count > Self.capacity { buffer.removeFirst(buffer.count - Self.capacity) }
        }

        func lines() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return buffer
        }

        /// True the first time only.
        func markBootstrapped() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if bootstrapped { return false }
            bootstrapped = true
            return true
        }
    }
}

/// A swift-log handler over `os.Logger`.
struct OSLogHandler: LogHandler {
    let label: String
    private let logger: os.Logger
    var logLevel: Logging.Logger.Level = .info
    var metadata: Logging.Logger.Metadata = [:]

    init(label: String) {
        self.label = label
        logger = os.Logger(subsystem: AppLogging.subsystem, category: label)
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    /// swift-log 1.7's entry point; the older signature below forwards here.
    func log(event: LogEvent) {
        emit(level: event.level, message: event.message, explicit: event.metadata)
    }

    func log(
        level: Logging.Logger.Level,
        message: Logging.Logger.Message,
        metadata explicit: Logging.Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        emit(level: level, message: message, explicit: explicit)
    }

    private func emit(
        level: Logging.Logger.Level,
        message: Logging.Logger.Message,
        explicit: Logging.Logger.Metadata?
    ) {
        var merged = self.metadata
        if let explicit { merged.merge(explicit) { $1 } }
        let suffix = merged.isEmpty ? "" : " " + merged.map { "\($0)=\($1)" }.sorted().joined(separator: " ")
        let text = "\(message)\(suffix)"
        // `privacy: .public`: the text is the app's own words about its own state, and a
        // record that shows as <private> in Console is no use in a bug report.
        switch level {
        case .trace, .debug: logger.debug("\(text, privacy: .public)")
        case .info, .notice: logger.info("\(text, privacy: .public)")
        case .warning: logger.warning("\(text, privacy: .public)")
        case .error: logger.error("\(text, privacy: .public)")
        case .critical: logger.critical("\(text, privacy: .public)")
        }
        if level >= .info {
            let stamp = ISO8601DateFormatter().string(from: Date())
            AppLogging.RecentRecords.shared.append("\(stamp) \(level) [\(label)] \(text)")
        }
    }
}
