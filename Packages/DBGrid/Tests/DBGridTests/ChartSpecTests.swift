import DBCore
import XCTest

@testable import DBGrid

final class ChartSpecTests: XCTestCase {
    private func column(
        _ index: Int, _ name: String, _ kind: DBValueKind, primaryKey: Bool? = nil
    ) -> ColumnMeta {
        ColumnMeta(
            id: index, name: name, nativeTypeName: kind.rawValue, kind: kind, isPrimaryKey: primaryKey)
    }

    /// The point of the whole thing: a key is a number, and drawing it as a bar says
    /// nothing. It is offered as a label instead.
    func testAKeyIsNeverAMeasure() {
        let columns = [
            column(0, "id", .int, primaryKey: true),
            column(1, "customer_id", .int),
            column(2, "uuid", .uuid),
            column(3, "total", .decimal),
            column(4, "name", .string),
        ]
        XCTAssertEqual(ChartSpec.measureColumns(columns), [3], "only total measures anything")
        XCTAssertTrue(ChartSpec.isIdentifier(columns[0]))
        XCTAssertTrue(ChartSpec.isIdentifier(columns[1]))
        XCTAssertTrue(ChartSpec.isIdentifier(columns[2]))
        XCTAssertFalse(ChartSpec.isIdentifier(columns[3]))
    }

    /// A number whose name merely ends in the letters i and d is still a number.
    func testAColumnThatMerelyEndsInTheLettersIsStillANumber() {
        for name in ["paid", "valid", "solid", "rapid", "void"] {
            XCTAssertFalse(ChartSpec.isIdentifier(column(0, name, .double)), name)
        }
    }

    /// Without a measure there is nothing to draw; a scatter needs a second one for x.
    func testTheShapesFollowWhatTheColumnsCanCarry() {
        XCTAssertEqual(ChartSpec.kinds(columns: [column(0, "id", .int, primaryKey: true)]), [])
        XCTAssertEqual(
            ChartSpec.kinds(columns: [column(0, "name", .string), column(1, "total", .double)]),
            [.bar, .line, .area, .pie])
        XCTAssertTrue(
            ChartSpec.kinds(columns: [column(0, "total", .double), column(1, "tax", .double)])
                .contains(.scatter))
    }

    /// The label a result opens on is the name beside the numbers, not the key.
    func testItOpensOnTheNameNotTheKey() {
        let columns = [
            column(0, "id", .int, primaryKey: true), column(1, "name", .string), column(2, "total", .double),
        ]
        let measure = ChartSpec.defaultMeasure(columns)
        XCTAssertEqual(measure, 2)
        XCTAssertEqual(ChartSpec.defaultCategory(columns, measure: measure), 1)
    }

    func testEachRowIsItsOwnPointUntilAnAggregateIsAskedFor() {
        let labels = ["a", "b", "a"]
        let values: [Double?] = [1, 2, 3]
        let raw = ChartSpec.plot(
            rowCount: 3, aggregate: .none, labelOf: { labels[$0] }, xOf: { _ in nil },
            valueOf: { values[$0] })
        XCTAssertEqual(raw.points.map(\.value), [1, 2, 3])

        let summed = ChartSpec.plot(
            rowCount: 3, aggregate: .sum, labelOf: { labels[$0] }, xOf: { _ in nil },
            valueOf: { values[$0] })
        XCTAssertEqual(summed.points.map(\.label), ["a", "b"], "first-seen order, not sorted")
        XCTAssertEqual(summed.points.map(\.value), [4, 2])

        let averaged = ChartSpec.plot(
            rowCount: 3, aggregate: .average, labelOf: { labels[$0] }, xOf: { _ in nil },
            valueOf: { values[$0] })
        XCTAssertEqual(averaged.points.map(\.value), [2, 2])

        let counted = ChartSpec.plot(
            rowCount: 3, aggregate: .count, labelOf: { labels[$0] }, xOf: { _ in nil },
            valueOf: { values[$0] })
        XCTAssertEqual(counted.points.map(\.value), [2, 1])
    }

    /// A row whose measure is NULL is left out rather than drawn as zero, which would be a
    /// different claim about the data.
    func testANullMeasureIsNotAZero() {
        let values: [Double?] = [1, nil, 3]
        let points = ChartSpec.plot(
            rowCount: 3, aggregate: .none, labelOf: { "r\($0)" }, xOf: { _ in nil },
            valueOf: { values[$0] })
        XCTAssertEqual(points.points.map(\.value), [1, 3])
    }

    func testDecimalsAndBoolsReadAsNumbersAndTextDoesNot() {
        XCTAssertEqual(ChartSpec.number(.decimal("12.50")), 12.5)
        XCTAssertEqual(ChartSpec.number(.int(7)), 7)
        XCTAssertEqual(ChartSpec.number(.bool(true)), 1)
        XCTAssertNil(ChartSpec.number(.string("happy")))
        XCTAssertNil(ChartSpec.number(.null))
    }

    /// A result pages, so a chart may only be able to read part of it. Summing what it
    /// could read and calling that the total is the failure this reports.
    func testItSaysHowManyRowsItCouldActuallyRead() {
        // Rows 2 and 3 are not resident: the caller cannot read them.
        let values: [Double?] = [10, nil, nil, 40]
        let plot = ChartSpec.plot(
            rowCount: 4, aggregate: .sum, labelOf: { _ in "all" }, xOf: { _ in nil },
            valueOf: { values[$0] })
        XCTAssertEqual(plot.points.map(\.value), [50], "only what it read")
        XCTAssertEqual(plot.rowsUsed, 2)
        XCTAssertEqual(plot.rowsTotal, 4)
        XCTAssertTrue(plot.isPartial, "and it says so")

        let whole = ChartSpec.plot(
            rowCount: 2, aggregate: .sum, labelOf: { _ in "all" }, xOf: { _ in nil },
            valueOf: { _ in 1 })
        XCTAssertFalse(whole.isPartial)
    }

    /// PostgreSQL's numeric stores NaN and its float stores Infinity. Neither can scale an
    /// axis, and a NaN never equals itself, so a point holding one could never be
    /// highlighted either.
    func testNonFiniteNumbersAreNotValues() {
        XCTAssertNil(ChartSpec.number(.decimal("NaN")))
        XCTAssertNil(ChartSpec.number(.string("Infinity")))
        XCTAssertNil(ChartSpec.number(.string("-inf")))
        XCTAssertEqual(ChartSpec.number(.decimal("1.5")), 1.5)
    }

    /// Only a number spaces an axis by value; a name is a position.
    func testOnlyANumberSpacesTheAxis() {
        XCTAssertTrue(ChartSpec.isContinuous(column(0, "total", .double)))
        XCTAssertFalse(ChartSpec.isContinuous(column(0, "name", .string)))
    }
}
