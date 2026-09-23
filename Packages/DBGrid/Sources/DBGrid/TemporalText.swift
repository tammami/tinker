import DBCore
import Foundation

/// Reads and writes the server's own text for dates, times and timestamps.
///
/// The server text is the truth and is never routed through `Date` for display; the
/// picker is a way to *produce* new text, so a value edited by hand and one edited with
/// the picker end up spelt the same way. Fractional seconds and a zone offset present in
/// the original are kept when the picker writes the value back.
public enum TemporalText {
    public struct Parts: Sendable, Hashable {
        public var date: Date
        public var fraction: String
        public var offset: String

        public init(date: Date, fraction: String, offset: String) {
            self.date = date
            self.fraction = fraction
            self.offset = offset
        }
    }

    public static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()

    /// Splits `2026-03-21 20:23:26.123+07` into a Date, its fraction and its offset.
    public static func parse(_ text: String, kind: DBValueKind) -> Parts? {
        var body = text.trimmingCharacters(in: .whitespaces)
        var offset = ""
        if kind != .date, let range = body.range(of: #"([+-]\d{2}(:?\d{2})?|Z)$"#, options: .regularExpression),
            range.lowerBound > body.startIndex, body[body.index(before: range.lowerBound)] != "-" || kind == .time
        {
            // A trailing zone only counts when it follows a time, not the date's own dashes.
            if body[..<range.lowerBound].contains(":") {
                offset = String(body[range])
                body = String(body[..<range.lowerBound])
            }
        }
        var fraction = ""
        if let dot = body.lastIndex(of: "."), body[body.index(after: dot)...].allSatisfy(\.isNumber) {
            fraction = String(body[dot...])
            body = String(body[..<dot])
        }
        let formats: [String] =
            switch kind {
            case .date: ["yyyy-MM-dd"]
            case .time: ["HH:mm:ss", "HH:mm"]
            default: ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"]
            }
        for format in formats {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = zone(for: offset) ?? .current
            formatter.dateFormat = format
            if let date = formatter.date(from: body) {
                return Parts(date: date, fraction: fraction, offset: offset)
            }
        }
        return nil
    }

    /// Writes a Date back in the shape the kind expects, keeping the original's fraction
    /// and offset.
    public static func render(_ date: Date, kind: DBValueKind, fraction: String, offset: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone(for: offset) ?? .current
        formatter.dateFormat =
            switch kind {
            case .date: "yyyy-MM-dd"
            case .time: "HH:mm:ss"
            default: "yyyy-MM-dd HH:mm:ss"
            }
        var text = formatter.string(from: date)
        if kind != .date { text += fraction }
        if kind != .date { text += offset }
        return text
    }

    public static func zone(for offset: String) -> TimeZone? {
        guard !offset.isEmpty else { return nil }
        if offset == "Z" { return TimeZone(secondsFromGMT: 0) }
        let sign = offset.hasPrefix("-") ? -1 : 1
        let digits = offset.dropFirst().replacingOccurrences(of: ":", with: "")
        guard let hours = Int(digits.prefix(2)) else { return nil }
        let minutes = digits.count >= 4 ? Int(digits.dropFirst(2).prefix(2)) ?? 0 : 0
        return TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60))
    }

    /// The offset `zone` is at on `date`, spelled the way PostgreSQL prints one: `+07`,
    /// or `+05:30` when there are minutes.
    public static func offsetText(for zone: TimeZone, at date: Date) -> String {
        let seconds = zone.secondsFromGMT(for: date)
        let sign = seconds < 0 ? "-" : "+"
        let hours = abs(seconds) / 3600
        let minutes = abs(seconds) % 3600 / 60
        let text = sign + String(format: "%02d", hours)
        return minutes == 0 ? text : text + String(format: ":%02d", minutes)
    }

    /// Whether a column stores an instant, so text written without an offset is read in
    /// the session's time zone rather than the one the user meant. PostgreSQL's type
    /// names only: its `timestamptz` and `timetz` take an offset in their input, while
    /// MySQL's TIMESTAMP does only from 8.0.19 and MariaDB's not at all, so those are
    /// left as they are.
    public static func isZoneAware(nativeType: String) -> Bool {
        let type = nativeType.lowercased()
        return type == "timestamptz" || type == "timetz" || type.contains("with time zone")
    }

    public static func isTemporal(_ kind: DBValueKind) -> Bool {
        kind == .date || kind == .time || kind == .timestamp
    }
}
