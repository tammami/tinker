import DBCore
import XCTest

@testable import DBSQL

final class EventOperationsTests: XCTestCase {
    private func request(
        name: String = "nightly_clear",
        schedule: EventSchedule = .every(value: "1", field: .day),
        starts: String? = "2026-01-01 00:00:00",
        ends: String? = nil,
        preserve: Bool = true,
        enabled: Bool = true,
        comment: String? = nil,
        body: String = "TRUNCATE TABLE staging"
    ) -> EventRequest {
        EventRequest(
            database: "shop", name: name, schedule: schedule, starts: starts, ends: ends,
            preserveOnCompletion: preserve, isEnabled: enabled, comment: comment, body: body)
    }

    func testCreateRendersARecurringScheduleWithItsStartAndComment() throws {
        let sql = try EventOperations.create(
            request(comment: "clears the staging table"), dialect: .mysql)
        XCTAssertEqual(
            sql,
            """
            CREATE EVENT `shop`.`nightly_clear`
            ON SCHEDULE EVERY 1 DAY
            STARTS '2026-01-01 00:00:00'
            ON COMPLETION PRESERVE
            ENABLE
            COMMENT 'clears the staging table'
            DO TRUNCATE TABLE staging
            """)
    }

    func testCreateRendersAOneTimeScheduleWithoutStartsOrEnds() throws {
        let sql = try EventOperations.create(
            request(schedule: .at("2026-03-01 23:00:00"), starts: nil, ends: nil), dialect: .mysql)
        XCTAssertTrue(sql.contains("ON SCHEDULE AT '2026-03-01 23:00:00'"), sql)
        XCTAssertFalse(sql.contains("STARTS"), sql)
        XCTAssertFalse(sql.contains("ENDS"), sql)
    }

    /// An event that runs once has no window. Dropping a start the caller asked for would
    /// be a silent disagreement, so the request is refused instead.
    func testAOneTimeScheduleRefusesAStartOrAnEnd() {
        XCTAssertThrowsError(
            try EventOperations.create(
                request(schedule: .at("2026-03-01 23:00:00"), starts: "2026-01-01 00:00:00"),
                dialect: .mysql)
        ) { XCTAssertEqual($0 as? EventOperationsError, .oneTimeTakesNoWindow) }
    }

    /// An edit that left the schedule alone must not re-state it: `ALTER EVENT` reads the
    /// timestamps in this session's time zone, and an event written in another would move.
    func testAnAlterCanLeaveTheScheduleAlone() throws {
        let sql = try EventOperations.alter(
            request(name: "nightly"), renamedFrom: "nightly", includingSchedule: false,
            dialect: .mysql)
        XCTAssertFalse(sql.contains("ON SCHEDULE"), sql)
        XCTAssertTrue(sql.contains("ALTER EVENT `shop`.`nightly`"), sql)
        XCTAssertTrue(sql.contains("DO TRUNCATE TABLE staging"), sql)
    }

    /// A blank `renamedFrom` names nothing; it must not become an empty identifier.
    func testABlankRenameFallsBackToTheEventsOwnName() throws {
        let sql = try EventOperations.alter(request(name: "nightly"), renamedFrom: "   ", dialect: .mysql)
        XCTAssertTrue(sql.hasPrefix("ALTER EVENT `shop`.`nightly`"), sql)
        XCTAssertFalse(sql.contains("RENAME TO"), sql)
    }

    /// The server refuses a negative or zero compound interval; the editor says so first.
    func testACompoundIntervalMustBePositive() {
        for bad in ["-5:30", "0:0", ":", "1 - 1"] {
            XCTAssertThrowsError(
                try EventOperations.create(
                    request(schedule: .every(value: bad, field: .hourMinute)), dialect: .mysql),
                "accepted \(bad)")
        }
        XCTAssertNoThrow(
            try EventOperations.create(
                request(schedule: .every(value: "1:30", field: .hourMinute)), dialect: .mysql))
    }

    /// Setting a DEFINER needs SUPER or SET_USER_ID, so an ordinary account spelling one
    /// out would simply be refused. The generator never writes it.
    func testCreateNeverWritesADefiner() throws {
        XCTAssertFalse(try EventOperations.create(request(), dialect: .mysql).contains("DEFINER"))
    }

    /// `NOT PRESERVE` is MySQL's own default and makes an event delete itself after its
    /// last run. The generator is always explicit so the stored event matches the editor.
    func testCompletionAndEnablementAreAlwaysSpeltOut() throws {
        let sql = try EventOperations.create(request(preserve: false, enabled: false), dialect: .mysql)
        XCTAssertTrue(sql.contains("ON COMPLETION NOT PRESERVE"), sql)
        XCTAssertTrue(sql.contains("DISABLE"), sql)
        XCTAssertFalse(sql.contains("\nENABLE"), sql)
    }

    func testEndsIsWrittenWhenTheScheduleStops() throws {
        let sql = try EventOperations.create(request(ends: "2027-01-01 00:00:00"), dialect: .mysql)
        XCTAssertTrue(sql.contains("ENDS '2027-01-01 00:00:00'"), sql)
    }

    func testAQuoteInANameCommentOrTimestampCannotBreakOutOfTheStatement() throws {
        let sql = try EventOperations.create(
            request(
                name: "ev`il", schedule: .at("2026-01-01' OR '1"), starts: nil,
                comment: "it's nightly"),
            dialect: .mysql)
        XCTAssertTrue(sql.contains("`shop`.`ev``il`"), sql)
        XCTAssertTrue(sql.contains("AT '2026-01-01'' OR ''1'"), sql)
        XCTAssertTrue(sql.contains("COMMENT 'it''s nightly'"), sql)
    }

    func testASimpleIntervalMustBeAWholeNumberGreaterThanZero() {
        for bad in ["1.5", "two", "1 DAY; DROP TABLE t", ""] {
            XCTAssertThrowsError(
                try EventOperations.create(
                    request(schedule: .every(value: bad, field: .hour)), dialect: .mysql),
                "accepted \(bad)")
        }
        XCTAssertThrowsError(
            try EventOperations.create(
                request(schedule: .every(value: "0", field: .hour)), dialect: .mysql)
        ) { error in
            XCTAssertEqual(error as? EventOperationsError, .intervalNotPositive("0"))
        }
        XCTAssertThrowsError(
            try EventOperations.create(
                request(schedule: .every(value: "-3", field: .hour)), dialect: .mysql))
    }

    func testACompoundIntervalIsQuotedAndItsShapeIsChecked() throws {
        let sql = try EventOperations.create(
            request(schedule: .every(value: "1:30", field: .hourMinute)), dialect: .mysql)
        XCTAssertTrue(sql.contains("ON SCHEDULE EVERY '1:30' HOUR_MINUTE"), sql)
        XCTAssertThrowsError(
            try EventOperations.create(
                request(schedule: .every(value: "1:30' OR '1", field: .hourMinute)), dialect: .mysql))
    }

    func testAnEventNeedsANameAndABody() {
        XCTAssertThrowsError(try EventOperations.create(request(name: "  "), dialect: .mysql)) {
            XCTAssertEqual($0 as? EventOperationsError, .emptyName)
        }
        XCTAssertThrowsError(try EventOperations.create(request(body: "\n  "), dialect: .mysql)) {
            XCTAssertEqual($0 as? EventOperationsError, .emptyBody)
        }
    }

    /// An edit alters rather than dropping and recreating, so a failed second half cannot
    /// lose the event.
    func testAlterRenamesInTheSameStatementItRescheduleWith() throws {
        let sql = try EventOperations.alter(
            request(name: "nightly_clear"), renamedFrom: "old_name", dialect: .mysql)
        XCTAssertTrue(sql.hasPrefix("ALTER EVENT `shop`.`old_name`"), sql)
        XCTAssertTrue(sql.contains("RENAME TO `shop`.`nightly_clear`"), sql)
        XCTAssertTrue(sql.contains("DO TRUNCATE TABLE staging"), sql)
    }

    func testAlterWithoutARenameDoesNotWriteRenameTo() throws {
        let sql = try EventOperations.alter(
            request(name: "nightly_clear"), renamedFrom: "nightly_clear", dialect: .mysql)
        XCTAssertFalse(sql.contains("RENAME TO"), sql)
    }

    func testEnableDisableAndDropAreSingleQuotedStatements() throws {
        XCTAssertEqual(
            try EventOperations.setEnabled(false, database: "shop", name: "nightly", dialect: .mysql),
            "ALTER EVENT `shop`.`nightly` DISABLE")
        XCTAssertEqual(
            try EventOperations.setEnabled(true, database: "shop", name: "nightly", dialect: .mysql),
            "ALTER EVENT `shop`.`nightly` ENABLE")
        XCTAssertEqual(
            try EventOperations.drop(database: "shop", name: "nightly", dialect: .mysql),
            "DROP EVENT IF EXISTS `shop`.`nightly`")
    }

    /// `SET GLOBAL` is forgotten at the next restart, which is exactly how someone ends up
    /// puzzled a second time. 8.0 and later get `SET PERSIST`.
    func testSchedulerStatementPersistsOnlyWhereTheServerSupportsIt() throws {
        XCTAssertEqual(
            try EventOperations.setScheduler(on: true, dialect: .mysql, persists: true),
            "SET PERSIST event_scheduler = ON")
        XCTAssertEqual(
            try EventOperations.setScheduler(on: true, dialect: .mysql, persists: false),
            "SET GLOBAL event_scheduler = ON")
        XCTAssertEqual(
            try EventOperations.setScheduler(on: false, dialect: .mysql, persists: true),
            "SET PERSIST event_scheduler = OFF")
    }

    func testOnlyMySQLEightAndLaterPersistsTheChange() {
        XCTAssertTrue(
            EventOperations.schedulerChangePersists(
                ServerVersion(major: 8, minor: 0, patch: 36, flavor: .mysql, rawString: "8.0.36")))
        XCTAssertTrue(
            EventOperations.schedulerChangePersists(
                ServerVersion(major: 9, minor: 4, patch: 0, flavor: .mysql, rawString: "9.4.0")))
        XCTAssertFalse(
            EventOperations.schedulerChangePersists(
                ServerVersion(major: 5, minor: 7, patch: 44, flavor: .mysql, rawString: "5.7.44")))
        XCTAssertFalse(
            EventOperations.schedulerChangePersists(
                ServerVersion(major: 11, minor: 4, patch: 0, flavor: .mariadb, rawString: "11.4.0")))
    }

    func testTheEnginesWithoutASchedulerAreRefusedInTheirOwnTerms() {
        for dialect in [SQLDialect.postgresql, .sqlite] {
            XCTAssertThrowsError(try EventOperations.create(request(), dialect: dialect)) { error in
                guard case .noScheduler = error as? EventOperationsError else {
                    return XCTFail("expected noScheduler for \(dialect), got \(error)")
                }
            }
            XCTAssertThrowsError(
                try EventOperations.drop(database: "shop", name: "nightly", dialect: dialect))
            XCTAssertThrowsError(
                try EventOperations.setScheduler(on: true, dialect: dialect, persists: false))
        }
        XCTAssertTrue(
            EventOperationsError.noScheduler(.postgresql).description.contains("pg_cron"))
    }
}
