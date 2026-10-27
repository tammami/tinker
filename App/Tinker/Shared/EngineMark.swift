import DBCore
import SwiftUI

/// The badge that tells a PostgreSQL connection from a MySQL, SQLite or Redis one at a glance.
///
/// Each engine shows its own logo from the asset catalogue (`Engine*` image sets, kept as
/// vector artwork so they stay sharp at any size). MariaDB shares MySQL's logo.
struct EngineMark: View {
    let dialect: SQLDialect
    /// MySQL and MariaDB share a dialect; only a live server says which. Nil until it has.
    var flavor: ServerFlavor?
    var size: CGFloat = 16
    /// A Redis connection, which has no SQL dialect to draw.
    var isRedis = false

    init(dialect: SQLDialect, flavor: ServerFlavor? = nil, size: CGFloat = 16) {
        self.dialect = dialect
        self.flavor = flavor
        self.size = size
    }

    /// The Redis badge.
    init(redis: Bool, size: CGFloat = 16) {
        dialect = .postgresql
        self.size = size
        isRedis = redis
    }

    /// The badge for a connection, whatever its engine.
    init(config: ConnectionConfig, flavor: ServerFlavor? = nil, size: CGFloat = 16) {
        dialect = config.dialect
        self.flavor = flavor ?? config.knownFlavor
        self.size = size
        isRedis = config.isRedis
    }

    var body: some View {
        // The logos are drawn for a light page, so they sit on a white tile of their own:
        // on a dark sidebar MySQL's teal and PostgreSQL's outline would otherwise vanish.
        let tile = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        ZStack {
            tile.fill(Color.white)
            tile.strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
            Image(logo)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size * 0.72, height: size * 0.72)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(isRedis ? "Redis" : Self.name(for: dialect, flavor: flavor))
    }

    /// The engine's logo in the asset catalogue.
    private var logo: String {
        if isRedis { return "EngineRedis" }
        switch dialect {
        case .postgresql: return "EnginePostgreSQL"
        case .mysql: return "EngineMySQL"
        case .sqlite: return "EngineSQLite"
        }
    }

    /// Redis's red.
    static let redisPlate = Color(red: 0.86, green: 0.22, blue: 0.18)

    static func name(for dialect: SQLDialect, flavor: ServerFlavor? = nil) -> String {
        switch dialect {
        case .postgresql: "PostgreSQL"
        case .mysql: flavor == .mariadb ? "MariaDB" : "MySQL"
        case .sqlite: "SQLite"
        }
    }
}
