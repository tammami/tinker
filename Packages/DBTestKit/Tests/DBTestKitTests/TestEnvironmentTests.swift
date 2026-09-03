import XCTest

@testable import DBTestKit

final class TestEnvironmentTests: XCTestCase {
    func testUnsetVariablesYieldNoServers() throws {
        XCTAssertEqual(try TestEnvironment.servers(for: .postgresql, environment: [:]), [])
        XCTAssertEqual(try TestEnvironment.servers(for: .mysql, environment: [:]), [])
    }

    func testPrimaryAndAdditionalURLsAreOrdered() throws {
        let env = [
            "DBSTUDIO_TEST_PG_URL": "postgresql://dbstudio_test:pw@localhost:5432/dbstudio_test",
            "DBSTUDIO_TEST_PG_URLS":
                " postgres://dbstudio_test@10.0.0.2/dbstudio_test , ,postgresql://dbstudio_test@10.0.0.3:5433/dbstudio_test",
        ]
        let servers = try TestEnvironment.servers(for: .postgresql, environment: env)
        XCTAssertEqual(servers.map(\.host), ["localhost", "10.0.0.2", "10.0.0.3"])
        XCTAssertEqual(servers.map(\.port), [5432, 5432, 5433])
        XCTAssertEqual(
            servers.map(\.source), ["DBSTUDIO_TEST_PG_URL", "DBSTUDIO_TEST_PG_URLS", "DBSTUDIO_TEST_PG_URLS"])
        XCTAssertEqual(servers[0].password, "pw")
        XCTAssertEqual(servers[0].database, "dbstudio_test")
    }

    func testRefusesOtherDatabases() {
        let env = ["DBSTUDIO_TEST_MYSQL_URL": "mysql://dbstudio_test:pw@127.0.0.1:3306/production"]
        XCTAssertThrowsError(try TestEnvironment.servers(for: .mysql, environment: env)) { error in
            guard case let TestEnvironmentError.wrongDatabase(_, database, expected)? = error as? TestEnvironmentError
            else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(database, "production")
            XCTAssertEqual(expected, "dbstudio_test")
        }
    }

    func testRefusesMissingDatabase() {
        let env = ["DBSTUDIO_TEST_MYSQL_URL": "mysql://dbstudio_test:pw@127.0.0.1:3306/"]
        XCTAssertThrowsError(try TestEnvironment.servers(for: .mysql, environment: env))
    }

    func testRefusesAdminUsers() {
        for user in ["root", "postgres", "ROOT"] {
            let env = ["DBSTUDIO_TEST_PG_URL": "postgresql://\(user):pw@localhost/dbstudio_test"]
            XCTAssertThrowsError(try TestEnvironment.servers(for: .postgresql, environment: env), user) { error in
                guard case TestEnvironmentError.adminUser? = error as? TestEnvironmentError else {
                    return XCTFail("unexpected error \(error)")
                }
            }
        }
    }

    func testRefusesWrongScheme() {
        let env = ["DBSTUDIO_TEST_PG_URL": "mysql://dbstudio_test@localhost/dbstudio_test"]
        XCTAssertThrowsError(try TestEnvironment.servers(for: .postgresql, environment: env)) { error in
            guard case TestEnvironmentError.wrongScheme? = error as? TestEnvironmentError else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testRefusesGarbage() {
        let env = ["DBSTUDIO_TEST_PG_URL": "not a url"]
        XCTAssertThrowsError(try TestEnvironment.servers(for: .postgresql, environment: env))
    }

    func testRedactedDescriptionHidesPassword() throws {
        let env = ["DBSTUDIO_TEST_PG_URL": "postgresql://dbstudio_test:s3cret@localhost/dbstudio_test"]
        let server = try XCTUnwrap(TestEnvironment.servers(for: .postgresql, environment: env).first)
        XCTAssertFalse(server.redactedDescription.contains("s3cret"))
        XCTAssertTrue(server.redactedDescription.contains("***"))
    }

    func testRequireServersSkipsWhenUnset() {
        XCTAssertThrowsError(try TestEnvironment.requireServers(for: .postgresql, environment: [:])) { error in
            XCTAssertTrue(error is XCTSkip, "expected XCTSkip, got \(error)")
        }
    }

    func testSummaryMentionsEveryEngine() {
        let summary = TestEnvironment.summary(environment: [:])
        XCTAssertTrue(summary.contains("postgresql: not configured"))
        XCTAssertTrue(summary.contains("mysql: not configured"))
    }

    /// Reports what the real environment provides. Never fails on its own; the
    /// engine-specific suites fail if a configured URL is invalid.
    @MainActor
    func testReportConfiguredEnvironment() {
        let summary = TestEnvironment.summary()
        for line in summary.split(separator: "\n") {
            // XCTest has no logger; XCTContext activities are the sanctioned way to annotate output.
            XCTContext.runActivity(named: "test environment: \(line)") { _ in }
        }
    }
}
