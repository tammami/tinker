import DBCore
import XCTest

@testable import DBGrid

/// A chart draws within a budget of marks, and says what it left out.
final class ChartBudgetTests: XCTestCase {
    private func points(_ values: [Double], x: Bool = false) -> [ChartPoint] {
        values.enumerated().map { ChartPoint(id: $0, label: "c\($0)", x: x ? Double($0) : nil, value: $1) }
    }

    private func plot(_ values: [Double], x: Bool = false) -> ChartPlot {
        ChartPlot(points: points(values, x: x), rowsUsed: values.count, rowsTotal: values.count)
    }

    private func rows(labels: [String], values: [DBValue?], xs: [DBValue?]? = nil, total: Int? = nil) -> ChartRows {
        var rows = ChartRows(rowsTotal: total ?? labels.count)
        for index in labels.indices {
            rows.append(
                row: index, label: .string(labels[index]), value: values[index], x: xs?[index], withX: xs != nil)
        }
        return rows
    }

    // MARK: - Bars

    func testBarsKeepTheLargestAndAddTheRestUpIntoOther() {
        let values = (1 ... 120).map(Double.init)
        let fitted = ChartSpec.fit(plot(values), kind: .bar, aggregate: .sum, budget: ChartBudget(categories: 50))
        XCTAssertEqual(fitted.points.count, 51, "fifty bars and Other")
        XCTAssertEqual(fitted.points.first?.value, 120, "largest first")
        XCTAssertEqual(fitted.points[49].value, 71)
        let other = fitted.points[50]
        XCTAssertTrue(other.isOther)
        XCTAssertEqual(other.label, "Other (70)")
        XCTAssertEqual(other.value, Double((1 ... 70).reduce(0, +)), "nothing is lost from the total")
        XCTAssertEqual(fitted.reduction, .top(shown: 50, of: 120, merged: 70))
        XCTAssertEqual(Set(fitted.points.map(\.id)).count, 51, "every point keeps an id of its own")
    }

    func testCountsMergeToo() {
        let fitted = ChartSpec.fit(
            plot((1 ... 30).map(Double.init)), kind: .bar, aggregate: .count, budget: ChartBudget(categories: 20))
        XCTAssertEqual(fitted.points.count, 21)
        XCTAssertEqual(fitted.points.last?.value, Double((1 ... 10).reduce(0, +)))
    }

    /// An average of averages is not an average, and unrelated rows are not a category.
    func testAveragesAndRowsAreLeftOutRatherThanAddedUp() {
        for aggregate in [ChartAggregate.average, .none] {
            let fitted = ChartSpec.fit(
                plot((1 ... 30).map(Double.init)), kind: .bar, aggregate: aggregate,
                budget: ChartBudget(categories: 20))
            XCTAssertEqual(fitted.points.count, 20, "\(aggregate)")
            XCTAssertFalse(fitted.points.contains(where: \.isOther), "\(aggregate)")
            XCTAssertEqual(fitted.reduction, .top(shown: 20, of: 30, merged: 0), "\(aggregate)")
        }
    }

    func testAPlotWithinItsBudgetIsLeftAsItWas() {
        let original = plot([3, 1, 2])
        let fitted = ChartSpec.fit(original, kind: .bar, aggregate: .sum)
        XCTAssertEqual(fitted.points, original.points, "its own order, not sorted")
        XCTAssertNil(fitted.reduction)
        XCTAssertNil(ChartSpec.caption(for: fitted, aggregate: .sum))
    }

    func testTiesKeepTheOrderTheRowsCameIn() {
        let fitted = ChartSpec.fit(
            plot(Array(repeating: 5, count: 40)), kind: .bar, aggregate: .none, budget: ChartBudget(categories: 20))
        XCTAssertEqual(fitted.points.map(\.id), Array(0 ..< 20))
    }

    // MARK: - Pie

    func testAPieHasEightSlicesAndOther() {
        let fitted = ChartSpec.fit(plot((1 ... 20).map(Double.init)), kind: .pie, aggregate: .sum)
        XCTAssertEqual(fitted.points.count, ChartBudget.slices + 1)
        XCTAssertEqual(fitted.points.last?.label, "Other (12)")
        XCTAssertEqual(fitted.points.reduce(0) { $0 + $1.value }, 210, "the whole is still the whole")
    }

    /// A negative value has no angle. It is left out and counted, never drawn as a slice.
    func testAPieLeavesOutWhatCannotBeAnAngle() {
        let fitted = ChartSpec.fit(plot([4, -2, 0, 6]), kind: .pie, aggregate: .sum)
        XCTAssertEqual(fitted.points.map(\.value), [4, 6])
        XCTAssertEqual(fitted.excluded, 2)
        XCTAssertEqual(ChartSpec.caption(for: fitted, aggregate: .sum), "2 zero or negative left out")
    }

    // MARK: - Lines

    func testALineKeepsItsPeaksItsTroughsItsEndsAndItsOrder() {
        var values = (0 ..< 48_000).map { sin(Double($0) / 300) * 10 }
        values[12_345] = 900
        values[40_001] = -700
        let fitted = ChartSpec.fit(plot(values, x: true), kind: .line, aggregate: .none)
        XCTAssertLessThanOrEqual(fitted.points.count, ChartBudget.linePoints)
        XCTAssertGreaterThan(fitted.points.count, ChartBudget.linePoints / 2)
        XCTAssertEqual(fitted.points.map(\.value).max(), 900, "the global peak survives")
        XCTAssertEqual(fitted.points.map(\.value).min(), -700, "and the global trough")
        XCTAssertEqual(fitted.points.first?.id, 0)
        XCTAssertEqual(fitted.points.last?.id, 47_999)
        XCTAssertEqual(fitted.points.map(\.id), fitted.points.map(\.id).sorted(), "in the order they came")
        XCTAssertEqual(Set(fitted.points.map(\.id)).count, fitted.points.count)
        XCTAssertEqual(fitted.reduction, .downsampled(shown: fitted.points.count, of: 48_000))
        XCTAssertEqual(
            ChartSpec.caption(for: fitted, aggregate: .none),
            "\(ChartSpec.grouped(fitted.points.count)) of 48,000 points (downsampled)")
    }

    func testAShortLineIsNotTouched() {
        let original = points((0 ..< 1_000).map(Double.init))
        XCTAssertEqual(ChartSpec.downsample(original, to: 1_000), original)
    }

    // MARK: - Scatter

    func testAScatterIsSampledEvenlyAndTheSameEveryTime() {
        let original = plot((0 ..< 50_000).map(Double.init), x: true)
        let first = ChartSpec.fit(original, kind: .scatter, aggregate: .none)
        let second = ChartSpec.fit(original, kind: .scatter, aggregate: .none)
        XCTAssertEqual(first.points.count, ChartBudget.scatterPoints)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.points[0].id, 0)
        XCTAssertEqual(first.points[1].id, 25)
        XCTAssertEqual(first.reduction, .sampled(shown: 2_000, of: 50_000))
    }

    // MARK: - Defaults

    func testRepeatedLabelsOpenOnASumAndUniqueOnesOnEachRow() {
        XCTAssertEqual(ChartSpec.suggestedAggregate(distinctLabels: 3, rows: 10), .sum)
        XCTAssertEqual(ChartSpec.suggestedAggregate(distinctLabels: 10, rows: 10), ChartAggregate.none)

        let repeated = ChartPlotter.draw(
            rows(labels: ["a", "b", "a", "b"], values: [.int(1), .int(2), .int(3), .int(4)]),
            ChartRequest(kind: .bar, aggregate: nil))
        XCTAssertEqual(repeated?.aggregate, .sum)
        XCTAssertEqual(repeated?.plot.points.map(\.value), [4, 6])

        let unique = ChartPlotter.draw(
            rows(labels: ["a", "b", "c"], values: [.int(1), .int(2), .int(3)]),
            ChartRequest(kind: .bar, aggregate: nil))
        XCTAssertEqual(unique?.aggregate, ChartAggregate.none)
    }

    func testAChoiceTheReaderMadeIsNeverOverridden() {
        let drawing = ChartPlotter.draw(
            rows(labels: ["a", "b", "a"], values: [.int(1), .int(2), .int(3)]),
            ChartRequest(kind: .bar, aggregate: ChartAggregate.none))
        XCTAssertEqual(drawing?.aggregate, ChartAggregate.none)
        XCTAssertEqual(drawing?.plot.points.count, 3)

        let average = ChartPlotter.draw(
            rows(labels: ["a", "b", "c"], values: [.int(1), .int(2), .int(3)]),
            ChartRequest(kind: .bar, aggregate: .average))
        XCTAssertEqual(average?.aggregate, .average)
    }

    func testUniqueLabelsPastTheBudgetShowTheTop() {
        let labels = (0 ..< 3_214).map { "row \($0)" }
        let drawing = ChartPlotter.draw(
            rows(labels: labels, values: labels.indices.map { .int(Int64($0)) }, total: 120_000),
            ChartRequest(kind: .bar, aggregate: nil))
        XCTAssertEqual(drawing?.aggregate, ChartAggregate.none)
        XCTAssertEqual(drawing?.plot.points.count, 50)
        XCTAssertEqual(drawing?.plot.points.first?.id, 3_213, "a row is named by its place in the result")
        XCTAssertEqual(drawing?.categoriesTotal, 3_214)
        XCTAssertEqual(drawing?.caption, "Top 50 of 3,214 rows, rest not drawn · 3,214 of 120,000 rows loaded")
    }

    // MARK: - What it says

    func testTheCaptionCountsCategoriesAndRows() {
        let labels = (0 ..< 5_000).map { "c\($0 % 3_214)" }
        let drawing = ChartPlotter.draw(
            rows(labels: labels, values: labels.map { _ in .int(1) }, total: 120_000),
            ChartRequest(kind: .bar, aggregate: .sum))
        XCTAssertEqual(drawing?.caption, "Top 50 of 3,214 categories · 5,000 of 120,000 rows loaded")
        XCTAssertEqual(drawing?.plot.rowsUsed, 5_000)
        XCTAssertEqual(drawing?.plot.rowsRead, 5_000)
        XCTAssertEqual(drawing?.plot.rowsTotal, 120_000)
    }

    /// A NULL measure was read; it is not a row that is missing from the grid.
    func testAnEmptyMeasureIsReadButNotUsed() {
        let drawing = ChartPlotter.draw(
            rows(labels: ["a", "b", "c"], values: [.int(1), .null, .int(3)]),
            ChartRequest(kind: .bar, aggregate: .sum))
        XCTAssertEqual(drawing?.plot.rowsUsed, 2)
        XCTAssertEqual(drawing?.plot.rowsRead, 3)
        XCTAssertEqual(drawing?.plot.isPartial, false)
        XCTAssertNil(drawing?.caption)
    }

    func testNonFiniteNumbersNeverReachTheChart() {
        let drawing = ChartPlotter.draw(
            rows(
                labels: ["a", "b", "c", "d"],
                values: [.decimal("NaN"), .double(.infinity), .string("-inf"), .decimal("2.5")]),
            ChartRequest(kind: .line, aggregate: ChartAggregate.none))
        XCTAssertEqual(drawing?.plot.points.map(\.value), [2.5])
    }

    func testGroupedCounts() {
        XCTAssertEqual(ChartSpec.grouped(0), "0")
        XCTAssertEqual(ChartSpec.grouped(999), "999")
        XCTAssertEqual(ChartSpec.grouped(1_000), "1,000")
        XCTAssertEqual(ChartSpec.grouped(1_234_567), "1,234,567")
    }

    func testAnAxisNeverPrintsMoreLabelsThanFit() {
        let many = points((0 ..< 101).map(Double.init))
        let labels = ChartSpec.axisLabels(many, limit: 24)
        XCTAssertLessThanOrEqual(labels.count, 24)
        XCTAssertEqual(labels.first, "c0")
        XCTAssertEqual(ChartSpec.axisLabels(points([1, 2, 3])), ["c0", "c1", "c2"])
    }

    // MARK: - Spacing by value

    func testALineSpacedByValueKeepsItsXAndASumDoesNot() {
        let source = rows(
            labels: ["1", "2", "3"], values: [.int(10), .int(20), .int(30)], xs: [.int(1), .int(2), .int(3)])
        let line = ChartPlotter.draw(source, ChartRequest(kind: .line, aggregate: ChartAggregate.none))
        XCTAssertEqual(line?.isContinuous, true)
        XCTAssertEqual(line?.plot.points.map(\.x), [1, 2, 3])
        let summed = ChartPlotter.draw(source, ChartRequest(kind: .line, aggregate: .sum))
        XCTAssertEqual(summed?.isContinuous, false)
    }

    // MARK: - Columns

    func testNamesComeBeforeNumbersAndKeysLast() {
        func column(_ index: Int, _ name: String, _ kind: DBValueKind) -> ColumnMeta {
            ColumnMeta(id: index, name: name, nativeTypeName: kind.rawValue, kind: kind, isPrimaryKey: nil)
        }
        let columns = [
            column(0, "id", .int), column(1, "total", .double), column(2, "created", .timestamp),
            column(3, "name", .string), column(4, "payload", .bytes), column(5, "city", .string),
        ]
        XCTAssertEqual(ChartSpec.rankedCategoryColumns(columns), [3, 5, 2, 1, 0])
    }

    // MARK: - Under the pointer

    func testThePointUnderThePointerIsFoundWithoutWalkingThePoints() {
        let scattered = [5.0, 1.0, 9.0, 3.0].enumerated().map {
            ChartPoint(id: $0, label: "p\($0)", x: $1, value: 0)
        }
        let index = ChartHitIndex(points: scattered)
        XCTAssertEqual(index.nearest(toX: 0), 1)
        XCTAssertEqual(index.nearest(toX: 3.4), 3)
        XCTAssertEqual(index.nearest(toX: 4.5), 0)
        XCTAssertEqual(index.nearest(toX: 100), 2)
        XCTAssertEqual(index.position(ofLabel: "p2"), 2)
        XCTAssertNil(index.position(ofLabel: "nobody"))
        XCTAssertNil(ChartHitIndex(points: points([1, 2])).nearest(toX: 1), "no x, nothing to be near")
    }

    // MARK: - Cancelling

    func testAnOvertakenRequestDrawsNothing() {
        let source = rows(labels: ["a"], values: [.int(1)])
        XCTAssertNil(ChartPlotter.draw(source, ChartRequest(kind: .bar, aggregate: nil), isCancelled: { true }))
    }

    func testThePlotterAnswersFromItsOwnActor() async {
        let drawing = await ChartPlotter().draw(
            rows(labels: ["a", "a"], values: [.int(1), .int(2)]), ChartRequest(kind: .pie, aggregate: nil))
        XCTAssertEqual(drawing?.plot.points.map(\.value), [3])
    }

    // MARK: - Speed

    /// 100,000 rows, every label its own: the worst a result can ask of the chart. The
    /// marks that come out are within the budget whatever went in.
    func testBuildingAChartFromAHundredThousandRowsIsQuick() {
        let count = 100_000
        var source = ChartRows(rowsTotal: count)
        source.reserveCapacity(count, withX: false)
        for index in 0 ..< count {
            source.append(
                row: index, label: .string("customer \(index)"), value: .decimal("\(index % 9_973).25"))
        }
        let request = ChartRequest(kind: .bar, aggregate: .sum)
        measure(metrics: [XCTClockMetric()]) {
            let drawing = ChartPlotter.draw(source, request)
            XCTAssertEqual(drawing?.plot.points.count, 51)
        }
        for kind in ChartKind.allCases {
            let drawing = ChartPlotter.draw(source, ChartRequest(kind: kind, aggregate: nil))
            XCTAssertLessThanOrEqual(drawing?.plot.points.count ?? .max, ChartBudget.scatterPoints, "\(kind)")
        }
    }
}
