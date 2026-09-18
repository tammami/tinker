import DBCore
import DBSQL
import XCTest

@testable import DBGrid

/// What puts a committed write back (ADR-0060).
final class RevertPlannerTests: XCTestCase {
    let table = TableRef(database: "app", schema: "public", name: "users")

    private func planner(identity: [String] = ["id"]) -> RevertPlanner {
        RevertPlanner(
            generator: DMLGenerator(dialect: .postgresql, table: table, identityColumns: identity),
            identityColumns: identity,
            columns: [
                ColumnMeta(id: 0, name: "id", nativeTypeName: "int4", kind: .int, isPrimaryKey: true),
                ColumnMeta(id: 1, name: "name", nativeTypeName: "text", kind: .string),
                ColumnMeta(id: 2, name: "note", nativeTypeName: "text", kind: .string),
            ])
    }

    /// The inverse writes back exactly the columns the edit changed, and nothing else.
    func testAnEditsInverseRestoresTheValuesItReplaced() throws {
        let statement = try planner().inverseOfUpdate(
            changes: ["name": .string("")],
            loaded: ["id": .int(7), "name": .string("Ada"), "note": .string("keep me")],
            originalIdentity: ["id": .int(7)])
        XCTAssertTrue(statement.sql.contains("SET"), statement.sql)
        XCTAssertTrue(statement.sql.contains("\"name\""))
        XCTAssertFalse(statement.sql.contains("\"note\""), "a column the edit never touched is left alone")
        XCTAssertEqual(statement.parameters.first, .string("Ada"), "the value as it was loaded")
        XCTAssertTrue(statement.expectsSingleRow, "it is checked like any other write")
    }

    /// An edit to the primary key moves the row; the inverse has to address it where the
    /// edit left it, or it would find nothing and fail its one-row check.
    func testAnEditToTheKeyIsUndoneWhereTheRowNowIs() throws {
        let after = RevertPlanner.identityAfter(
            ["id": .int(7)], changes: ["id": .int(9), "name": .string("Ada")], identityColumns: ["id"])
        XCTAssertEqual(after, ["id": .int(9)])

        let statement = try planner().inverseOfUpdate(
            changes: ["id": .int(9)],
            loaded: ["id": .int(7), "name": .string("Ada")],
            originalIdentity: ["id": .int(7)])
        XCTAssertEqual(statement.parameters, [.int(7), .int(9)], "set the old key, find the new one")
    }

    /// A column the grid never loaded has no known previous value, and guessing NULL
    /// would destroy data, so the write is simply not offered as revertible.
    func testAColumnThatWasNeverLoadedBlocksTheRevert() {
        XCTAssertThrowsError(
            try planner().inverseOfUpdate(
                changes: ["hidden": .string("x")],
                loaded: ["id": .int(7)],
                originalIdentity: ["id": .int(7)])
        ) { error in
            XCTAssertEqual(error as? RevertError, .valueNotLoaded("hidden"))
        }
    }

    func testADeletedRowGoesBackWhole() throws {
        let statement = try planner().inverseOfDelete(
            loadedRow: ["id": .int(7), "name": .string("Ada"), "note": .null])
        XCTAssertEqual(statement.kind, .insert)
        XCTAssertTrue(statement.sql.contains("\"note\""), "every column comes back, NULLs included")
        XCTAssertThrowsError(try planner().inverseOfDelete(loadedRow: [:])) { error in
            XCTAssertEqual(error as? RevertError, .rowNotLoaded)
        }
    }

    func testANewRowIsUndoneByDeletingTheKeyTheServerGave() throws {
        let statement = try planner().inverseOfInsert(identity: ["id": .int(31)])
        XCTAssertEqual(statement.kind, .delete)
        XCTAssertEqual(statement.parameters, [.int(31)])
        XCTAssertThrowsError(try planner().inverseOfInsert(identity: [:])) { error in
            XCTAssertEqual(error as? RevertError, .keyNotReported("id"))
        }
    }

    /// Where the new row's key comes from: the row PostgreSQL returned, the value the user
    /// typed, or the number MySQL reported — and nothing at all for a composite key the
    /// server only answered with one number.
    func testTheNewRowsKeyIsReadFromWhateverTheServerAnswered() {
        let returned = RevertPlanner.insertedIdentity(
            identityColumns: ["id"], supplied: [:],
            returnedRow: [.int(4), .string("Ada")],
            returnedColumns: [
                ColumnMeta(id: 0, name: "id", nativeTypeName: "int4", kind: .int),
                ColumnMeta(id: 1, name: "name", nativeTypeName: "text", kind: .string),
            ],
            lastInsertID: nil)
        XCTAssertEqual(returned, ["id": .int(4)])

        let typed = RevertPlanner.insertedIdentity(
            identityColumns: ["id"], supplied: ["id": .int(12)], returnedRow: nil, returnedColumns: [],
            lastInsertID: nil)
        XCTAssertEqual(typed, ["id": .int(12)], "a key the user typed names the row without the server's help")

        let generated = RevertPlanner.insertedIdentity(
            identityColumns: ["id"], supplied: [:], returnedRow: nil, returnedColumns: [], lastInsertID: 88)
        XCTAssertEqual(generated, ["id": .int(88)], "MySQL answers with a number")

        let composite = RevertPlanner.insertedIdentity(
            identityColumns: ["tenant", "id"], supplied: ["tenant": .int(1)], returnedRow: nil,
            returnedColumns: [], lastInsertID: 88)
        XCTAssertNil(composite, "one number cannot name a two-column key")
    }
}

/// The plan a whole commit produces, through the model that holds the loaded rows.
@MainActor
final class GridModelRevertTests: XCTestCase {
    private func loadedModel() async -> GridModel {
        let loader = FixtureLoader(totalRows: 5, pageSize: 10)
        let model = GridModel(
            source: .table(TableRef(database: "app", schema: "public", name: "big_table")),
            dialect: .postgresql,
            loader: loader,
            identityColumns: ["id"],
            identityKind: .int)
        model.editTarget = TableRef(database: "app", schema: "public", name: "big_table")
        await model.load(page: 0)
        return model
    }

    /// The whole point: after the write has landed and the buffer is empty, the plan still
    /// holds the value that was replaced.
    func testTheValueACommitReplacedSurvivesInThePlan() async throws {
        let model = await loadedModel()
        let before = model.value(row: 1, column: 1)
        model.setValue(.string("wiped"), row: 1, column: 1)
        let outcome = try await model.commitRecordingRevert(using: ScriptedRunner(affected: [1]))

        XCTAssertEqual(outcome.result.statementCount, 1)
        XCTAssertTrue(outcome.revert.isRevertible)
        XCTAssertEqual(outcome.revert.statements.count, 1)
        XCTAssertEqual(outcome.revert.statements[0].parameters.first, before)
        XCTAssertFalse(model.canUndo, "the buffer's own history is gone, as it always was")
    }

    /// A delete's inverse carries every column of the row, which is only knowable before
    /// the row leaves the server.
    func testADeleteIsPutBackWithTheRowItRemoved() async throws {
        let model = await loadedModel()
        _ = model.markDeleted(rows: [1])
        let outcome = try await model.commitRecordingRevert(using: ScriptedRunner(affected: [1]))
        XCTAssertTrue(outcome.revert.isRevertible)
        XCTAssertEqual(outcome.revert.statements.first?.kind, .insert)
        XCTAssertTrue(outcome.revert.statements[0].parameters.contains(.int(1)))
    }

    /// A grid with no primary key cannot be written at all, so there is nothing to put
    /// back and nothing to claim.
    func testAGridWithNothingToKeyOnOffersNoRevert() async throws {
        let loader = FixtureLoader(totalRows: 3, pageSize: 10)
        let model = GridModel(source: .query("SELECT 1"), dialect: .postgresql, loader: loader)
        await model.load(page: 0)
        let outcome = try await model.commitRecordingRevert(using: ScriptedRunner())
        XCTAssertFalse(outcome.revert.isRevertible)
        XCTAssertEqual(outcome.result.statementCount, 0)
    }
}
