import DBCore
import Foundation

/// One entry in the designer's type pop-up.
public struct ColumnTypeChoice: Sendable, Hashable, Identifiable {
    /// The name the engine's documentation leads with, spelled as the server writes it
    /// back: `bigint`, `character varying`, `INTEGER` on SQLite.
    public let name: String
    /// Other names the engine accepts for the same type: `int8` for `bigint`, `varchar`
    /// for `character varying`. A column declared with one is this type.
    public let aliases: [String]
    /// The documentation's own chapter for the type: "Numeric", "Date/Time".
    public let group: String
    /// What the documentation says of the type in one line: storage and range.
    public let summary: String
    /// Whether the type takes a length: `varchar(255)`, `decimal(10,2)`.
    public let takesLength: Bool
    /// Whether the type takes decimals after its length.
    public let takesDecimals: Bool
    /// The modifiers the type can carry after its length — `unsigned`, `with time zone`
    /// — with the empty string standing for "none". Empty when the type takes no modifier.
    public let suffixes: [String]
    /// True for a name that only means something when a column is created: PostgreSQL's
    /// `serial` is shorthand for an integer with a sequence, not a type a column can be
    /// altered to.
    public let isCreationOnly: Bool

    public var id: String { name }

    /// The name with its aliases, as the pop-up shows it: `bigint · int8`.
    public var title: String {
        aliases.isEmpty ? name : "\(name) · \(aliases.joined(separator: ", "))"
    }

    public init(
        _ name: String,
        aliases: [String] = [],
        group: String = "",
        summary: String = "",
        takesLength: Bool = false,
        takesDecimals: Bool = false,
        suffixes: [String] = [],
        isCreationOnly: Bool = false
    ) {
        self.name = name
        self.aliases = aliases
        self.group = group
        self.summary = summary
        self.takesLength = takesLength
        self.takesDecimals = takesDecimals
        self.suffixes = suffixes
        self.isCreationOnly = isCreationOnly
    }

    /// True when `text` is this type's name or one of its aliases, whatever its case.
    public func answers(to text: String) -> Bool {
        let lower = text.lowercased()
        return name.lowercased() == lower || aliases.contains { $0.lowercased() == lower }
    }
}

/// The types each server's designer offers: every type the engine's documentation
/// lists, under the documentation's own names and in its own chapters.
///
/// - PostgreSQL: "Data Types", Table 8.1 and the sections that follow it.
/// - MySQL: "Data Types" (numeric, date and time, string, spatial, JSON, vector);
///   MariaDB's own types are added when the server is MariaDB.
/// - SQLite: "Datatypes In SQLite" — the storage classes, and the declared names of its
///   affinity table, which decide a column's affinity and nothing else.
public enum ColumnTypeCatalog {
    /// The types of `dialect`, narrowed to what `version` has when it is known: a type a
    /// server does not have is not offered to it.
    public static func choices(for dialect: SQLDialect, version: ServerVersion? = nil) -> [ColumnTypeChoice] {
        switch dialect {
        case .mysql: mysql(version)
        case .postgresql: postgresql(version)
        case .sqlite: sqlite
        }
    }

    /// The pop-up entry for a base type or one of its aliases, or nil for a type the
    /// list does not carry.
    public static func choice(
        named base: String, dialect: SQLDialect, version: ServerVersion? = nil
    ) -> ColumnTypeChoice? {
        let all = choices(for: dialect, version: version)
        let lower = base.lowercased()
        // A name wins over an alias: MySQL's `real` is an alias of `double`, and would
        // otherwise be found first under whatever type happened to list it.
        return all.first { $0.name.lowercased() == lower } ?? all.first { $0.answers(to: base) }
    }

    static let unsignedChoices = ["", "unsigned", "unsigned zerofill"]
    static let zoneChoices = ["without time zone", "with time zone"]

    // MARK: - SQLite

    /// SQLite stores by affinity: a declared type is a name the affinity is worked out
    /// from, by the five rules of its documentation. The storage classes come first,
    /// then the declared names of the documentation's affinity table, then the names
    /// Tinker reads specially.
    static let sqlite: [ColumnTypeChoice] = {
        let integer = "Affinity and declared names: INTEGER"
        let text = "Affinity and declared names: TEXT"
        let real = "Affinity and declared names: REAL"
        let numeric = "Affinity and declared names: NUMERIC"
        let blob = "Affinity and declared names: BLOB"
        return [
            ColumnTypeChoice(
                "INTEGER", aliases: ["INT"], group: integer,
                summary: "INTEGER affinity. A signed integer stored in 0, 1, 2, 3, 4, 6 or 8 bytes by magnitude. "
                    + "INTEGER PRIMARY KEY is an alias of the rowid, and the only column that takes AUTOINCREMENT."),
            ColumnTypeChoice("TINYINT", group: integer, summary: "INTEGER affinity: the name contains INT."),
            ColumnTypeChoice("SMALLINT", group: integer, summary: "INTEGER affinity: the name contains INT."),
            ColumnTypeChoice("MEDIUMINT", group: integer, summary: "INTEGER affinity: the name contains INT."),
            ColumnTypeChoice("BIGINT", group: integer, summary: "INTEGER affinity: the name contains INT."),
            ColumnTypeChoice(
                "UNSIGNED BIG INT", group: integer,
                summary: "INTEGER affinity: the name contains INT. SQLite integers are always signed, 8 bytes at most."
            ),
            ColumnTypeChoice("INT2", group: integer, summary: "INTEGER affinity: the name contains INT."),
            ColumnTypeChoice("INT8", group: integer, summary: "INTEGER affinity: the name contains INT."),

            ColumnTypeChoice(
                "TEXT", group: text,
                summary: "TEXT affinity. A string in the database encoding (UTF-8, UTF-16BE or UTF-16LE)."),
            ColumnTypeChoice(
                "CHARACTER", group: text, summary: "TEXT affinity: the name contains CHAR. The length is not enforced.",
                takesLength: true),
            ColumnTypeChoice(
                "VARCHAR", group: text, summary: "TEXT affinity: the name contains CHAR. The length is not enforced.",
                takesLength: true),
            ColumnTypeChoice(
                "VARYING CHARACTER", group: text,
                summary: "TEXT affinity: the name contains CHAR. The length is not enforced.", takesLength: true),
            ColumnTypeChoice(
                "NCHAR", group: text, summary: "TEXT affinity: the name contains CHAR. The length is not enforced.",
                takesLength: true),
            ColumnTypeChoice(
                "NATIVE CHARACTER", group: text,
                summary: "TEXT affinity: the name contains CHAR. The length is not enforced.", takesLength: true),
            ColumnTypeChoice(
                "NVARCHAR", group: text, summary: "TEXT affinity: the name contains CHAR. The length is not enforced.",
                takesLength: true),
            ColumnTypeChoice("CLOB", group: text, summary: "TEXT affinity: the name contains CLOB."),

            ColumnTypeChoice(
                "BLOB", group: blob,
                summary: "BLOB affinity (called NONE before 3.8.9). Bytes stored exactly as they were given."),

            ColumnTypeChoice("REAL", group: real, summary: "REAL affinity. An 8-byte IEEE floating point number."),
            ColumnTypeChoice("DOUBLE", group: real, summary: "REAL affinity: the name contains DOUB."),
            ColumnTypeChoice("DOUBLE PRECISION", group: real, summary: "REAL affinity: the name contains DOUB."),
            ColumnTypeChoice("FLOAT", group: real, summary: "REAL affinity: the name contains FLOA."),

            ColumnTypeChoice(
                "NUMERIC", group: numeric,
                summary: "NUMERIC affinity. Text that looks like a number is stored as INTEGER or REAL; "
                    + "anything else is kept as it was given.",
                takesLength: true, takesDecimals: true),
            ColumnTypeChoice(
                "DECIMAL", group: numeric,
                summary: "NUMERIC affinity. The precision and scale are not enforced; "
                    + "values past 15 digits lose digits as REAL.",
                takesLength: true, takesDecimals: true),
            ColumnTypeChoice(
                "BOOLEAN", group: numeric,
                summary: "NUMERIC affinity. SQLite has no boolean: TRUE and FALSE are 1 and 0."
            ),
            ColumnTypeChoice(
                "DATE", group: numeric,
                summary: "NUMERIC affinity. SQLite has no date type: dates are ISO-8601 text, Julian day REALs "
                    + "or Unix time INTEGERs, read by its date and time functions."),
            ColumnTypeChoice(
                "DATETIME", group: numeric,
                summary: "NUMERIC affinity. Stored as ISO-8601 text, a Julian day REAL or a Unix time INTEGER."),
            ColumnTypeChoice(
                "TIME", group: numeric, summary: "NUMERIC affinity. A time of day, by convention ISO-8601 text."),
            ColumnTypeChoice(
                "TIMESTAMP", group: numeric,
                summary: "NUMERIC affinity. Stored as ISO-8601 text, a Julian day REAL or a Unix time INTEGER."),

            ColumnTypeChoice(
                "ANY", group: "STRICT tables",
                summary: "In a STRICT table: any value, stored exactly as given with no conversion. "
                    + "In an ordinary table the name has NUMERIC affinity."),
            ColumnTypeChoice(
                "JSON", group: "Conventions",
                summary: "NUMERIC affinity by name. JSON is text read by the JSON functions; JSONB (3.45) is a BLOB."),
            ColumnTypeChoice(
                "UUID", group: "Conventions",
                summary: "NUMERIC affinity by name. By convention 36 characters of text or 16 bytes of BLOB."),
        ]
    }()

    // MARK: - MySQL

    static func mysql(_ version: ServerVersion?) -> [ColumnTypeChoice] {
        let isMariaDB = version?.flavor == .mariadb
        var types = mysqlNumeric + mysqlDateTime + mysqlString
        if isMariaDB, let version {
            types += mariaDBTypes(version)
        } else {
            types.append(
                ColumnTypeChoice(
                    "json", group: "JSON",
                    summary: "A validated JSON document in a binary format that reads a member without parsing "
                        + "the whole. About as large as LONGTEXT; cannot have a non-NULL default."))
            if version.map({ $0.isAtLeast(9, 0) }) ?? true {
                types.append(
                    ColumnTypeChoice(
                        "vector", group: "Vector",
                        summary: "MySQL 9.0. Up to N 4-byte floating point entries; N defaults to 2048 "
                            + "and cannot pass 16383.",
                        takesLength: true))
            }
        }
        return types + mysqlSpatial
            + [
                // MySQL 8.0 took `geomcollection` as the name it writes back; MariaDB
                // knows the long name only.
                ColumnTypeChoice(
                    "geometrycollection", aliases: isMariaDB ? [] : ["geomcollection"], group: "Spatial",
                    summary: "A collection of geometries of any type.")
            ]
    }

    static let mysqlNumeric: [ColumnTypeChoice] = [
        ColumnTypeChoice(
            "tinyint", group: "Numeric", summary: "1 byte. −128 to 127; unsigned 0 to 255.", takesLength: true,
            suffixes: unsignedChoices),
        ColumnTypeChoice(
            "smallint", group: "Numeric", summary: "2 bytes. −32768 to 32767; unsigned 0 to 65535.",
            takesLength: true, suffixes: unsignedChoices),
        ColumnTypeChoice(
            "mediumint", group: "Numeric", summary: "3 bytes. −8388608 to 8388607; unsigned 0 to 16777215.",
            takesLength: true, suffixes: unsignedChoices),
        ColumnTypeChoice(
            "int", aliases: ["integer"], group: "Numeric",
            summary: "4 bytes. −2147483648 to 2147483647; unsigned 0 to 4294967295. "
                + "The display width is deprecated since 8.0.17.",
            takesLength: true, suffixes: unsignedChoices),
        ColumnTypeChoice(
            "bigint", group: "Numeric",
            summary: "8 bytes. −9223372036854775808 to 9223372036854775807; unsigned 0 to 18446744073709551615.",
            takesLength: true, suffixes: unsignedChoices),
        ColumnTypeChoice(
            "serial", group: "Numeric",
            summary: "An alias for BIGINT UNSIGNED NOT NULL AUTO_INCREMENT UNIQUE.", isCreationOnly: true),
        ColumnTypeChoice(
            "decimal", aliases: ["dec", "numeric", "fixed"], group: "Numeric",
            summary: "Exact. DECIMAL(M,D): M digits in all, at most 65 (default 10); D after the point, "
                + "at most 30 (default 0).",
            takesLength: true, takesDecimals: true, suffixes: unsignedChoices),
        ColumnTypeChoice(
            "float", group: "Numeric",
            summary: "4 bytes, approximate: about 7 significant digits. FLOAT(M,D) is deprecated since 8.0.17.",
            takesLength: true, takesDecimals: true, suffixes: unsignedChoices),
        ColumnTypeChoice(
            "double", aliases: ["double precision", "real"], group: "Numeric",
            summary: "8 bytes, approximate: about 15 significant digits. DOUBLE(M,D) is deprecated since 8.0.17.",
            takesLength: true, takesDecimals: true, suffixes: unsignedChoices),
        ColumnTypeChoice(
            "bit", group: "Numeric", summary: "BIT(M): M bits, 1 to 64 (default 1).", takesLength: true),
        ColumnTypeChoice(
            "boolean", aliases: ["bool"], group: "Numeric",
            summary: "A synonym for TINYINT(1), which is how the server writes it back. "
                + "Zero is false; any other value is true."),
    ]

    static let mysqlDateTime: [ColumnTypeChoice] = [
        ColumnTypeChoice("date", group: "Date and Time", summary: "3 bytes. '1000-01-01' to '9999-12-31'."),
        ColumnTypeChoice(
            "time", group: "Date and Time",
            summary: "'-838:59:59.000000' to '838:59:59.000000': a time of day or an elapsed time. "
                + "The length is the fractional seconds, 0 to 6.",
            takesLength: true),
        ColumnTypeChoice(
            "datetime", group: "Date and Time",
            summary: "'1000-01-01 00:00:00' to '9999-12-31 23:59:59', stored as written with no time zone. "
                + "The length is the fractional seconds, 0 to 6.",
            takesLength: true),
        ColumnTypeChoice(
            "timestamp", group: "Date and Time",
            summary: "'1970-01-01 00:00:01' UTC to '2038-01-19 03:14:07' UTC, stored in UTC and shown in the "
                + "session's time zone. The length is the fractional seconds, 0 to 6.",
            takesLength: true),
        ColumnTypeChoice(
            "year", group: "Date and Time", summary: "1 byte. 1901 to 2155, and 0000."),
    ]

    static let mysqlString: [ColumnTypeChoice] = [
        ColumnTypeChoice(
            "char", aliases: ["character"], group: "String",
            summary: "CHAR(M): a fixed length of 0 to 255 characters, padded with spaces when stored.",
            takesLength: true),
        ColumnTypeChoice(
            "varchar", aliases: ["character varying"], group: "String",
            summary: "VARCHAR(M): up to M characters. A row holds at most 65535 bytes, "
                + "so the most M can be depends on the character set.",
            takesLength: true),
        ColumnTypeChoice(
            "nchar", aliases: ["national char"], group: "String",
            summary: "CHAR in the national character set, utf8mb3. The server writes it back as char.",
            takesLength: true),
        ColumnTypeChoice(
            "nvarchar", aliases: ["national varchar"], group: "String",
            summary: "VARCHAR in the national character set, utf8mb3. The server writes it back as varchar.",
            takesLength: true),
        ColumnTypeChoice("tinytext", group: "String", summary: "Up to 255 bytes of text."),
        ColumnTypeChoice(
            "text", group: "String", summary: "Up to 65535 bytes (64 KiB) of text. Cannot have a literal default."),
        ColumnTypeChoice("mediumtext", group: "String", summary: "Up to 16777215 bytes (16 MiB) of text."),
        ColumnTypeChoice("longtext", group: "String", summary: "Up to 4294967295 bytes (4 GiB) of text."),
        ColumnTypeChoice(
            "binary", group: "String", summary: "BINARY(M): a fixed length of 0 to 255 bytes, padded with 0x00.",
            takesLength: true),
        ColumnTypeChoice(
            "varbinary", group: "String", summary: "VARBINARY(M): up to M bytes, compared byte by byte.",
            takesLength: true),
        ColumnTypeChoice("tinyblob", group: "String", summary: "Up to 255 bytes."),
        ColumnTypeChoice("blob", group: "String", summary: "Up to 65535 bytes (64 KiB)."),
        ColumnTypeChoice("mediumblob", group: "String", summary: "Up to 16777215 bytes (16 MiB)."),
        ColumnTypeChoice("longblob", group: "String", summary: "Up to 4294967295 bytes (4 GiB)."),
        ColumnTypeChoice(
            "enum", group: "String",
            summary: "One value from a list of up to 65535 members, stored as its 1- or 2-byte index."),
        ColumnTypeChoice(
            "set", group: "String",
            summary: "Any number of values from a list of up to 64 members, stored as a bitmap of 1 to 8 bytes."),
    ]

    static let mysqlSpatial: [ColumnTypeChoice] = [
        ColumnTypeChoice("geometry", group: "Spatial", summary: "A geometry of any type."),
        ColumnTypeChoice("point", group: "Spatial", summary: "One location."),
        ColumnTypeChoice("linestring", group: "Spatial", summary: "A curve of straight segments between points."),
        ColumnTypeChoice("polygon", group: "Spatial", summary: "A surface with one outer ring and any inner rings."),
        ColumnTypeChoice("multipoint", group: "Spatial", summary: "A collection of points."),
        ColumnTypeChoice("multilinestring", group: "Spatial", summary: "A collection of linestrings."),
        ColumnTypeChoice("multipolygon", group: "Spatial", summary: "A collection of polygons."),
    ]

    /// What MariaDB has that MySQL does not, each from the release that brought it.
    static func mariaDBTypes(_ version: ServerVersion) -> [ColumnTypeChoice] {
        var types = [
            ColumnTypeChoice(
                "json", group: "JSON",
                summary: "MariaDB: an alias for LONGTEXT with a JSON_VALID check, "
                    + "which is how the server writes it back.")
        ]
        if version.isAtLeast(10, 7) {
            types.append(
                ColumnTypeChoice("uuid", group: "MariaDB", summary: "MariaDB 10.7. A 128-bit UUID in 16 bytes."))
        }
        if version.isAtLeast(10, 5) {
            types.append(
                ColumnTypeChoice(
                    "inet6", group: "MariaDB", summary: "MariaDB 10.5. An IPv6 address, or IPv4 mapped, in 16 bytes."))
        }
        if version.isAtLeast(10, 10) {
            types.append(
                ColumnTypeChoice("inet4", group: "MariaDB", summary: "MariaDB 10.10. An IPv4 address in 4 bytes."))
        }
        if version.isAtLeast(11, 7) {
            types.append(
                ColumnTypeChoice(
                    "vector", group: "MariaDB",
                    summary: "MariaDB 11.7. VECTOR(N): N 4-byte floating point entries, for a vector index.",
                    takesLength: true))
        }
        return types
    }

    // MARK: - PostgreSQL

    static func postgresql(_ version: ServerVersion?) -> [ColumnTypeChoice] {
        var types = postgresqlCore
        if version.map({ $0.isAtLeast(14) }) ?? true { types += postgresqlMultiranges }
        types += postgresqlIdentifiers
        if version.map({ $0.isAtLeast(13) }) ?? true {
            types.append(
                ColumnTypeChoice(
                    "pg_snapshot", group: "System",
                    summary: "A snapshot of transaction ids: which were in progress at a moment."))
        }
        return types + postgresqlExtensions
    }

    static let postgresqlCore: [ColumnTypeChoice] = [
        ColumnTypeChoice(
            "smallint", aliases: ["int2"], group: "Numeric", summary: "2 bytes. −32768 to +32767."),
        ColumnTypeChoice(
            "integer", aliases: ["int", "int4"], group: "Numeric",
            summary: "4 bytes. −2147483648 to +2147483647. The usual choice for an integer."),
        ColumnTypeChoice(
            "bigint", aliases: ["int8"], group: "Numeric",
            summary: "8 bytes. −9223372036854775808 to +9223372036854775807."),
        ColumnTypeChoice(
            "numeric", aliases: ["decimal"], group: "Numeric",
            summary: "Exact, variable size. Up to 131072 digits before the decimal point and 16383 after. "
                + "Without a precision it keeps every digit it is given.",
            takesLength: true, takesDecimals: true),
        ColumnTypeChoice(
            "real", aliases: ["float4"], group: "Numeric",
            summary: "4 bytes, inexact: 6 decimal digits of precision."),
        ColumnTypeChoice(
            "double precision", aliases: ["float8"], group: "Numeric",
            summary: "8 bytes, inexact: 15 decimal digits of precision."),
        ColumnTypeChoice(
            "smallserial", aliases: ["serial2"], group: "Numeric",
            summary: "A smallint numbered by its own sequence, 1 to 32767. "
                + "Shorthand at creation; the server writes it back as smallint with a nextval default.",
            isCreationOnly: true),
        ColumnTypeChoice(
            "serial", aliases: ["serial4"], group: "Numeric",
            summary: "An integer numbered by its own sequence, 1 to 2147483647. "
                + "Shorthand at creation; the server writes it back as integer with a nextval default.",
            isCreationOnly: true),
        ColumnTypeChoice(
            "bigserial", aliases: ["serial8"], group: "Numeric",
            summary: "A bigint numbered by its own sequence, 1 to 9223372036854775807. "
                + "Shorthand at creation; the server writes it back as bigint with a nextval default.",
            isCreationOnly: true),

        ColumnTypeChoice(
            "money", group: "Monetary",
            summary: "8 bytes. −92233720368547758.08 to +92233720368547758.07, "
                + "with the fractional precision of lc_monetary."),

        ColumnTypeChoice(
            "character varying", aliases: ["varchar"], group: "Character",
            summary: "Up to n characters; without a length, any size. No slower than text.", takesLength: true),
        ColumnTypeChoice(
            "character", aliases: ["char", "bpchar"], group: "Character",
            summary: "A fixed length of n characters, padded with spaces. Without a length it is character(1).",
            takesLength: true),
        ColumnTypeChoice(
            "text", group: "Character", summary: "A string of any length, up to 1 GB. PostgreSQL's native string type."
        ),

        ColumnTypeChoice(
            "bytea", group: "Binary", summary: "A binary string of any length, up to 1 GB; 1 or 4 bytes of overhead."),

        // PostgreSQL writes the precision before the zone words — `timestamp(6) with
        // time zone` — so the zone is a modifier of `time`/`timestamp`, not part of the base.
        ColumnTypeChoice(
            "timestamp", group: "Date/Time",
            summary: "8 bytes. 4713 BC to 294276 AD, to the microsecond. With time zone (timestamptz) it is "
                + "stored in UTC and shown in the session's zone. The length is the fractional seconds, 0 to 6.",
            takesLength: true, suffixes: zoneChoices),
        ColumnTypeChoice(
            "timestamptz", group: "Date/Time",
            summary: "The alias of timestamp with time zone, which is how the server writes it back.",
            takesLength: true),
        ColumnTypeChoice("date", group: "Date/Time", summary: "4 bytes. 4713 BC to 5874897 AD, to the day."),
        ColumnTypeChoice(
            "time", group: "Date/Time",
            summary: "8 bytes, 00:00:00 to 24:00:00; 12 bytes with time zone (timetz). "
                + "The length is the fractional seconds, 0 to 6.",
            takesLength: true, suffixes: zoneChoices),
        ColumnTypeChoice(
            "timetz", group: "Date/Time",
            summary: "The alias of time with time zone, which is how the server writes it back.",
            takesLength: true),
        ColumnTypeChoice(
            "interval", group: "Date/Time",
            summary: "16 bytes. −178000000 to +178000000 years, to the microsecond. "
                + "The length is the fractional seconds, 0 to 6.",
            takesLength: true),

        ColumnTypeChoice(
            "boolean", aliases: ["bool"], group: "Boolean", summary: "1 byte. true, false, or NULL for unknown."),

        ColumnTypeChoice("point", group: "Geometric", summary: "16 bytes. A point on a plane: (x,y)."),
        ColumnTypeChoice("line", group: "Geometric", summary: "24 bytes. An infinite line: {A,B,C}."),
        ColumnTypeChoice("lseg", group: "Geometric", summary: "32 bytes. A line segment: [(x1,y1),(x2,y2)]."),
        ColumnTypeChoice("box", group: "Geometric", summary: "32 bytes. A rectangle: (x1,y1),(x2,y2)."),
        ColumnTypeChoice(
            "path", group: "Geometric", summary: "16+16n bytes. A closed path ((x1,y1),…) or an open one [(x1,y1),…]."),
        ColumnTypeChoice("polygon", group: "Geometric", summary: "40+16n bytes. A polygon: ((x1,y1),…)."),
        ColumnTypeChoice("circle", group: "Geometric", summary: "24 bytes. A centre and a radius: <(x,y),r>."),

        ColumnTypeChoice(
            "inet", group: "Network Address",
            summary: "7 or 19 bytes. An IPv4 or IPv6 host, with its network's netmask if given."),
        ColumnTypeChoice(
            "cidr", group: "Network Address",
            summary: "7 or 19 bytes. An IPv4 or IPv6 network; bits to the right of the netmask must be zero."),
        ColumnTypeChoice("macaddr", group: "Network Address", summary: "6 bytes. A MAC address."),
        ColumnTypeChoice("macaddr8", group: "Network Address", summary: "8 bytes. A MAC address in EUI-64 format."),

        ColumnTypeChoice(
            "bit", group: "Bit String", summary: "Exactly n bits. Without a length it is bit(1).", takesLength: true),
        ColumnTypeChoice(
            "bit varying", aliases: ["varbit"], group: "Bit String",
            summary: "Up to n bits; without a length, any number.", takesLength: true),

        ColumnTypeChoice(
            "tsvector", group: "Text Search", summary: "A document made ready for text search: sorted lexemes."),
        ColumnTypeChoice("tsquery", group: "Text Search", summary: "A text search query: lexemes and operators."),

        ColumnTypeChoice(
            "uuid", group: "UUID", summary: "16 bytes. A universally unique identifier (RFC 9562)."),
        ColumnTypeChoice(
            "xml", group: "XML", summary: "An XML document or content, checked for being well-formed."),
        ColumnTypeChoice(
            "json", group: "JSON",
            summary: "JSON kept as the text it was given: spaces, key order and repeated keys are all preserved."),
        ColumnTypeChoice(
            "jsonb", group: "JSON",
            summary: "JSON in a decomposed binary form: slower to write, faster to read, and it can be indexed (GIN)."
        ),

        ColumnTypeChoice("int4range", group: "Range", summary: "A range of integer."),
        ColumnTypeChoice("int8range", group: "Range", summary: "A range of bigint."),
        ColumnTypeChoice("numrange", group: "Range", summary: "A range of numeric."),
        ColumnTypeChoice("tsrange", group: "Range", summary: "A range of timestamp without time zone."),
        ColumnTypeChoice("tstzrange", group: "Range", summary: "A range of timestamp with time zone."),
        ColumnTypeChoice("daterange", group: "Range", summary: "A range of date."),
    ]

    static let postgresqlMultiranges: [ColumnTypeChoice] = [
        ColumnTypeChoice("int4multirange", group: "Multirange", summary: "PostgreSQL 14. Ranges of integer."),
        ColumnTypeChoice("int8multirange", group: "Multirange", summary: "PostgreSQL 14. Ranges of bigint."),
        ColumnTypeChoice("nummultirange", group: "Multirange", summary: "PostgreSQL 14. Ranges of numeric."),
        ColumnTypeChoice(
            "tsmultirange", group: "Multirange", summary: "PostgreSQL 14. Ranges of timestamp without time zone."),
        ColumnTypeChoice(
            "tstzmultirange", group: "Multirange", summary: "PostgreSQL 14. Ranges of timestamp with time zone."),
        ColumnTypeChoice("datemultirange", group: "Multirange", summary: "PostgreSQL 14. Ranges of date."),
    ]

    static let postgresqlIdentifiers: [ColumnTypeChoice] = [
        ColumnTypeChoice(
            "oid", group: "Object Identifier", summary: "4 bytes, unsigned. The identifier of a catalog row."),
        ColumnTypeChoice("regclass", group: "Object Identifier", summary: "A relation, by name: pg_class."),
        ColumnTypeChoice("regcollation", group: "Object Identifier", summary: "A collation, by name: pg_collation."),
        ColumnTypeChoice(
            "regconfig", group: "Object Identifier", summary: "A text search configuration: pg_ts_config."),
        ColumnTypeChoice("regdictionary", group: "Object Identifier", summary: "A text search dictionary: pg_ts_dict."),
        ColumnTypeChoice("regnamespace", group: "Object Identifier", summary: "A schema, by name: pg_namespace."),
        ColumnTypeChoice("regoper", group: "Object Identifier", summary: "An operator, by name: pg_operator."),
        ColumnTypeChoice(
            "regoperator", group: "Object Identifier", summary: "An operator with its argument types: pg_operator."),
        ColumnTypeChoice("regproc", group: "Object Identifier", summary: "A function, by name: pg_proc."),
        ColumnTypeChoice(
            "regprocedure", group: "Object Identifier", summary: "A function with its argument types: pg_proc."),
        ColumnTypeChoice("regrole", group: "Object Identifier", summary: "A role, by name: pg_authid."),
        ColumnTypeChoice("regtype", group: "Object Identifier", summary: "A data type, by name: pg_type."),

        ColumnTypeChoice(
            "pg_lsn", group: "System", summary: "8 bytes. A log sequence number: a position in the write-ahead log."),
        ColumnTypeChoice(
            "txid_snapshot", group: "System",
            summary: "A snapshot of transaction ids. Deprecated in favour of pg_snapshot."),
        ColumnTypeChoice(
            "name", group: "System", summary: "64 bytes. The type of an identifier in the catalogs; 63 characters."),
    ]

    /// Not PostgreSQL's own: they exist once the extension is created in the database,
    /// and the server says so in its own words when it is not.
    static let postgresqlExtensions: [ColumnTypeChoice] = [
        ColumnTypeChoice(
            "geometry", group: "PostGIS (extension)", summary: "PostGIS. A shape on a plane, in the SRID's units."),
        ColumnTypeChoice(
            "geography", group: "PostGIS (extension)",
            summary: "PostGIS. A shape on the earth's surface, measured in metres."),
    ]
}
