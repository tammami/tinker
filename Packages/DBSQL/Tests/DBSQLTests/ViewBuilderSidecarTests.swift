import DBCore
import XCTest

@testable import DBSQL

final class ViewBuilderSidecarTests: XCTestCase {
    private func model() -> QueryBuilderModel {
        var model = QueryBuilderModel()
        _ = model.add(TableRef(database: "db", schema: "public", name: "customers"))
        return model
    }

    func testFingerprintIgnoresWhitespaceAndCaseButNotContent() {
        let a = ViewBuilderSidecar.fingerprint("SELECT a FROM t")
        XCTAssertEqual(a, ViewBuilderSidecar.fingerprint("select   a\n  from t;"))
        XCTAssertEqual(a, ViewBuilderSidecar.fingerprint("  SELECT\tA FROM T ;;  "))
        XCTAssertNotEqual(a, ViewBuilderSidecar.fingerprint("SELECT a, b FROM t"))
    }

    func testMatchesTheDefinitionItWasSavedAgainst() {
        let sidecar = ViewBuilderSidecar(model: model(), serverDefinition: "SELECT * FROM customers")
        XCTAssertTrue(sidecar.matches(serverDefinition: "select *\nfrom customers;"))
        XCTAssertFalse(sidecar.matches(serverDefinition: "SELECT * FROM customers WHERE tier = 'ok'"))
    }

    func testRoundTripsThroughCodable() throws {
        let sidecar = ViewBuilderSidecar(model: model(), serverDefinition: "SELECT * FROM customers")
        let data = try JSONEncoder().encode(sidecar)
        let back = try JSONDecoder().decode(ViewBuilderSidecar.self, from: data)
        XCTAssertEqual(back, sidecar)
        XCTAssertEqual(back.model.tables.first?.ref.name, "customers")
    }
}
