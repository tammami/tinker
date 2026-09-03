import Foundation
import Logging

/// Maps a dialect to the driver that speaks it.
///
/// The app registers the concrete drivers at launch, which is what lets `ConnectionSession`
/// live in `DBCore` without `DBCore` ever importing a driver (SPEC §3).
public struct DriverRegistry: Sendable {
    private let drivers: [SQLDialect: any SQLDriver.Type]

    public init(_ drivers: [SQLDialect: any SQLDriver.Type] = [:]) {
        self.drivers = drivers
    }

    public func driver(for dialect: SQLDialect) throws -> any SQLDriver.Type {
        guard let driver = drivers[dialect] else {
            throw DBError.connectionFailed(
                underlying: "No driver is registered for \(dialect.rawValue)",
                hint: "Register the driver at launch"
            )
        }
        return driver
    }

    public func connect(
        _ config: ResolvedConnectionConfig,
        logger: Logger
    ) async throws -> any SQLConnection {
        try await driver(for: config.dialect).connect(config, logger: logger)
    }

    public var registeredDialects: Set<SQLDialect> { Set(drivers.keys) }

    /// The default port for a dialect, from its driver when one is registered.
    public func defaultPort(for dialect: SQLDialect) -> Int {
        (try? driver(for: dialect).defaultPort) ?? (dialect == .postgresql ? 5432 : 3306)
    }
}
