import DBCore
import DBPostgres
import DBTestKit
import Logging
import XCTest

@testable import DBGrid

/// SPEC §12.6 measured the way §17 asks: with `XCTMetric`, not by eye. The clock metric
/// times the first page of the million-row fixture through the real loader; the memory
/// metric watches the process while fifty pages are read in turn, which is what paging
/// through the table costs. The signpost metric reads the `page load` intervals
/// `GridModel` emits, so the same numbers show in Instruments.
///
/// `measure` records; it does not fail on its own. The explicit assertions below hold
/// the §12.6 numbers (first page under 500 ms) so a regression fails the build, and the
/// metric output in the log is what a baseline is set from in Xcode.
final class GridPerformanceTests: XCTestCase {
    var logger: Logger {
        var logger = Logger(label: "test.grid.perf")
        logger.logLevel = .critical
        return logger
    }

    private func makeSession() async throws -> (ConnectionSession, TestServer)? {
        let servers = try TestEnvironment.servers(for: .postgresql)
        guard let server = servers.first else {
            throw XCTSkip("TINKER_TEST_PG_URL not set; the million-row fixture is PostgreSQL's")
        }
        let config = ConnectionConfig(
            name: "grid-perf", dialect: .postgresql, host: server.host, port: server.port,
            user: server.user, database: server.database
        )
        let secrets = EphemeralSecretStore()
        var withPassword = config
        if let password = server.password {
            let reference = SecretRef.forConnection(config.id, field: "password")
            try await secrets.setSecret(password, for: reference)
            withPassword.passwordRef = reference
        }
        let session = ConnectionSession(
            config: withPassword,
            registry: DriverRegistry([.postgresql: PostgresDriver.self]),
            secrets: secrets, logger: logger
        )
        return (session, server)
    }

    @MainActor
    private static func makeModel(_ session: ConnectionSession, _ server: TestServer) -> GridModel {
        let table = server.table("big_table")
        let model = GridModel(
            source: .table(table), dialect: .postgresql,
            loader: SessionGridLoader(session: session, table: table, dialect: .postgresql),
            identityColumns: ["id"], identityKind: .int
        )
        model.isPaged = true
        return model
    }

    func testFirstPageClockAndSignposts() async throws {
        guard let (session, server) = try await makeSession() else { return }
        defer { Task { await session.disconnect() } }
        try await session.connect()
        let model = await Self.makeModel(session, server)

        // Warm: the first call pays for the pooled connection, which is not the page.
        await model.load(page: 0)
        let warm = await MainActor.run { model.rowCount }
        XCTAssertEqual(warm, 1_000)

        let options = XCTMeasureOptions()
        options.iterationCount = 5
        let metrics: [any XCTMetric] = [
            XCTClockMetric(),
            XCTOSSignpostMetric(subsystem: "com.thinkfree.Tinker", category: "grid", name: "page load"),
        ]
        measure(metrics: metrics, options: options) {
            let done = expectation(description: "page")
            Task { @MainActor in
                await model.reload()
                done.fulfill()
            }
            wait(for: [done], timeout: 10)
        }

        // The §12.6 bound, held as an assertion as well as recorded as a metric.
        let started = ContinuousClock.now
        await model.reload()
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(500))
        let reloaded = await MainActor.run { model.rowCount }
        XCTAssertEqual(reloaded, 1_000)
    }

    func testPagingThroughTheTableKeepsMemoryFlat() async throws {
        guard let (session, server) = try await makeSession() else { return }
        defer { Task { await session.disconnect() } }
        try await session.connect()
        let model = await Self.makeModel(session, server)
        await model.load(page: 0)

        let options = XCTMeasureOptions()
        options.iterationCount = 2
        measure(metrics: [XCTMemoryMetric()], options: options) {
            let done = expectation(description: "pages")
            Task { @MainActor in
                for page in 1 ... 50 { await model.goToPage(page) }
                done.fulfill()
            }
            wait(for: [done], timeout: 60)
        }
        // One page resident at a time: the buffer never holds more than the page size.
        let (resident, pageSize) = await MainActor.run { (model.rowCount, model.pageSize) }
        XCTAssertLessThanOrEqual(resident, pageSize)
    }
}
