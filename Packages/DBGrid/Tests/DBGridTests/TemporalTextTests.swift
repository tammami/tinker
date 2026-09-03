import DBCore
import Foundation
import XCTest

@testable import DBGrid

final class TemporalTextTests: XCTestCase {
    func testTimestampWithFractionAndOffsetRoundTrips() throws {
        let text = "2026-09-03 13:32:13.947375+08"
        let parts = try XCTUnwrap(TemporalText.parse(text, kind: .timestamp))
        XCTAssertEqual(parts.fraction, ".947375")
        XCTAssertEqual(parts.offset, "+08")
        XCTAssertEqual(
            TemporalText.render(parts.date, kind: .timestamp, fraction: parts.fraction, offset: parts.offset), text)
        // Moving the date by a day keeps the time, fraction and zone as they were.
        let tomorrow = try XCTUnwrap(TemporalText.calendar.date(byAdding: .day, value: 1, to: parts.date))
        XCTAssertEqual(
            TemporalText.render(tomorrow, kind: .timestamp, fraction: parts.fraction, offset: parts.offset),
            "2026-09-04 13:32:13.947375+08"
        )
    }

    func testMySQLDatetimeWithoutZoneAndISOFormRoundTrip() throws {
        let plain = try XCTUnwrap(TemporalText.parse("2026-03-21 20:23:26", kind: .timestamp))
        XCTAssertEqual(plain.offset, "")
        XCTAssertEqual(
            TemporalText.render(plain.date, kind: .timestamp, fraction: "", offset: ""), "2026-03-21 20:23:26")
        let iso = try XCTUnwrap(TemporalText.parse("2026-03-21T20:23:26Z", kind: .timestamp))
        XCTAssertEqual(iso.offset, "Z")
        XCTAssertEqual(
            TemporalText.render(iso.date, kind: .timestamp, fraction: "", offset: "Z"), "2026-03-21 20:23:26Z")
    }

    func testDateAndTimeKinds() throws {
        let date = try XCTUnwrap(TemporalText.parse("2024-02-29", kind: .date))
        XCTAssertEqual(TemporalText.render(date.date, kind: .date, fraction: "", offset: ""), "2024-02-29")
        let time = try XCTUnwrap(TemporalText.parse("02:30:00.5+07", kind: .time))
        XCTAssertEqual(time.fraction, ".5")
        XCTAssertEqual(time.offset, "+07")
        XCTAssertEqual(
            TemporalText.render(time.date, kind: .time, fraction: time.fraction, offset: time.offset), "02:30:00.5+07")
        XCTAssertNil(TemporalText.parse("not a date", kind: .timestamp))
        XCTAssertTrue(TemporalText.isTemporal(.timestamp))
        XCTAssertFalse(TemporalText.isTemporal(.string))
    }
}
