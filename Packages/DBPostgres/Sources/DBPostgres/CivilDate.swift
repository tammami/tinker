import DBCore
import Foundation

/// Proleptic Gregorian calendar arithmetic on integer day counts.
///
/// Used instead of `Foundation.Calendar` so that dates outside the range Foundation
/// handles comfortably — year 1 and year 9999, PostgreSQL's BC dates — stay exact and
/// so that no value ever passes through `Date`.
enum CivilDate {
    /// Days from 1970-01-01 to 2000-01-01, PostgreSQL's epoch.
    static let postgresEpochDaysFromUnix = 10_957
    /// Seconds from 2000-01-01 (PostgreSQL's epoch) to 2001-01-01 (Foundation's).
    static let postgresToReferenceSeconds = 31_622_400

    /// Converts days since 1970-01-01 into a proleptic Gregorian date, using
    /// astronomical year numbering, where year 0 is 1 BC.
    ///
    /// Howard Hinnant's `civil_from_days`, which is exact for the whole Int range.
    static func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let shifted = days + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPrime = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1
        let month = monthPrime < 10 ? monthPrime + 3 : monthPrime - 9
        return (month <= 2 ? year + 1 : year, month, day)
    }

    /// Inverse of ``civilFromDays(_:)``.
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let monthPrime = month > 2 ? month - 3 : month + 9
        let dayOfYear = (153 * monthPrime + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// Splits microseconds since midnight into a time of day, carrying whole days out.
    /// Handles negative input, which PostgreSQL produces for timestamps before its epoch.
    static func timeFromMicroseconds(_ microseconds: Int64) -> (dayCarry: Int, time: DBTime) {
        let usecPerDay: Int64 = 86_400_000_000
        var remainder = microseconds % usecPerDay
        var carry = microseconds / usecPerDay
        if remainder < 0 {
            remainder += usecPerDay
            carry -= 1
        }
        let microsecond = Int(remainder % 1_000_000)
        let totalSeconds = Int(remainder / 1_000_000)
        return (
            Int(carry),
            DBTime(
                hour: totalSeconds / 3_600,
                minute: (totalSeconds % 3_600) / 60,
                second: totalSeconds % 60,
                microsecond: microsecond
            )
        )
    }

    /// Renders a date the way PostgreSQL does under `DateStyle = ISO`, including the
    /// `BC` suffix for astronomical years at or below zero.
    static func render(date: DBDate) -> String {
        guard date.year <= 0 else { return date.description }
        let bcYear = 1 - date.year
        let yearText = bcYear < 10_000 ? String(format: "%04d", bcYear) : String(bcYear)
        return "\(yearText)-\(DBDate.pad2(date.month))-\(DBDate.pad2(date.day)) BC"
    }
}
