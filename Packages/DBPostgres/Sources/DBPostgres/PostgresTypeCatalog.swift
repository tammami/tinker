import DBCore
import Foundation

/// What `pg_type` says about one type.
public struct PostgresTypeInfo: Sendable, Hashable {
    /// `pg_type.typname`, the name shown for unmapped types.
    public let name: String
    /// `pg_type.typtype`: b base, c composite, d domain, e enum, p pseudo, r range, m multirange.
    public let type: Character
    /// `pg_type.typcategory`: S string, N numeric, D date/time, B boolean, A array, E enum, …
    public let category: Character
    /// Element type for an array, else 0.
    public let elementOID: UInt32
    /// Base type for a domain, else 0.
    public let baseOID: UInt32

    public init(name: String, type: Character, category: Character, elementOID: UInt32, baseOID: UInt32) {
        self.name = name
        self.type = type
        self.category = category
        self.elementOID = elementOID
        self.baseOID = baseOID
    }
}

/// The server's type table, read once per connection.
///
/// Built-in types are decoded from their well-known OIDs without consulting the catalog;
/// the catalog exists to name and classify user-defined types — enums, domains, composites
/// and arrays of those — which have installation-specific OIDs.
public struct PostgresTypeCatalog: Sendable {
    private var types: [UInt32: PostgresTypeInfo]

    public init(types: [UInt32: PostgresTypeInfo] = [:]) {
        self.types = types
    }

    public subscript(oid: UInt32) -> PostgresTypeInfo? { types[oid] }

    public var count: Int { types.count }

    /// The query that loads the catalog. Reads only built-in catalogs, so it needs no privileges.
    public static let loadQuery = """
        SELECT oid::int8, typname, typtype::text, typcategory::text, typelem::int8, typbasetype::int8
        FROM pg_catalog.pg_type
        """

    /// Builds a catalog from the rows of ``loadQuery``.
    public static func make(from rows: [[DBValue]]) -> PostgresTypeCatalog {
        var types: [UInt32: PostgresTypeInfo] = [:]
        types.reserveCapacity(rows.count)
        for row in rows where row.count >= 6 {
            guard case let .int(oid) = row[0], oid >= 0,
                  case let .string(name) = row[1]
            else { continue }
            let typeChar = row[2].text?.first ?? "b"
            let categoryChar = row[3].text?.first ?? "U"
            let elementOID = if case let .int(value) = row[4], value >= 0 { UInt32(value) } else { UInt32(0) }
            let baseOID = if case let .int(value) = row[5], value >= 0 { UInt32(value) } else { UInt32(0) }
            types[UInt32(oid)] = PostgresTypeInfo(
                name: name, type: typeChar, category: categoryChar,
                elementOID: elementOID, baseOID: baseOID
            )
        }
        return PostgresTypeCatalog(types: types)
    }

    /// Follows a domain to the type it is built on, so a domain decodes like its base type.
    /// Bounded, because a malformed catalog must not loop forever.
    public func resolvingDomain(_ oid: UInt32) -> UInt32 {
        var current = oid
        for _ in 0 ..< 8 {
            guard let info = types[current], info.type == "d", info.baseOID != 0 else { return current }
            current = info.baseOID
        }
        return current
    }
}

/// OIDs of the built-in types the driver maps explicitly. Values come from
/// `include/catalog/pg_type.dat` and are stable across every PostgreSQL release.
public enum PGOID {
    public static let bool: UInt32 = 16
    public static let bytea: UInt32 = 17
    public static let char: UInt32 = 18
    public static let name: UInt32 = 19
    public static let int8: UInt32 = 20
    public static let int2: UInt32 = 21
    public static let int4: UInt32 = 23
    public static let regproc: UInt32 = 24
    public static let text: UInt32 = 25
    public static let oid: UInt32 = 26
    public static let tid: UInt32 = 27
    public static let xid: UInt32 = 28
    public static let cid: UInt32 = 29
    public static let json: UInt32 = 114
    public static let xml: UInt32 = 142
    public static let pgNodeTree: UInt32 = 194
    public static let point: UInt32 = 600
    public static let float4: UInt32 = 700
    public static let float8: UInt32 = 701
    public static let unknown: UInt32 = 705
    public static let money: UInt32 = 790
    public static let macaddr: UInt32 = 829
    public static let inet: UInt32 = 869
    public static let cidr: UInt32 = 650
    public static let macaddr8: UInt32 = 774
    public static let bpchar: UInt32 = 1042
    public static let varchar: UInt32 = 1043
    public static let date: UInt32 = 1082
    public static let time: UInt32 = 1083
    public static let timestamp: UInt32 = 1114
    public static let timestamptz: UInt32 = 1184
    public static let interval: UInt32 = 1186
    public static let timetz: UInt32 = 1266
    public static let bit: UInt32 = 1560
    public static let varbit: UInt32 = 1562
    public static let numeric: UInt32 = 1700
    public static let uuid: UInt32 = 2950
    public static let jsonb: UInt32 = 3802
    public static let regtype: UInt32 = 2206

    /// Array OIDs paired with their element OID, for the types above.
    public static let arrayElement: [UInt32: UInt32] = [
        1000: bool, 1001: bytea, 1002: char, 1003: name, 1016: int8, 1005: int2, 1007: int4,
        1009: text, 1028: oid, 199: json, 143: xml, 1017: point, 1021: float4, 1022: float8,
        791: money, 1040: macaddr, 1041: inet, 651: cidr, 775: macaddr8, 1014: bpchar,
        1015: varchar, 1182: date, 1183: time, 1115: timestamp, 1185: timestamptz,
        1187: interval, 1270: timetz, 1561: bit, 1563: varbit, 1231: numeric, 2951: uuid,
        3807: jsonb, 2211: regtype, 1013: regproc,
    ]

    /// Types whose binary form is exactly their UTF-8 text.
    public static let textLike: Set<UInt32> = [
        char, name, text, bpchar, varchar, xml, json, unknown, pgNodeTree, regproc, regtype,
    ]

    /// The value kind each mapped OID produces, used for `ColumnMeta` before rows arrive.
    ///
    /// The cases are written with an explicit `PGOID.` prefix on purpose: a bare `oid`
    /// in a case pattern would resolve to the parameter and match everything.
    public static func kind(for typeOID: UInt32, catalog: PostgresTypeCatalog) -> DBValueKind {
        let resolved = catalog.resolvingDomain(typeOID)
        if arrayElement[resolved] != nil { return .array }
        switch resolved {
        case PGOID.bool: return .bool
        case PGOID.int2, PGOID.int4, PGOID.int8, PGOID.oid, PGOID.xid, PGOID.cid: return .int
        case PGOID.float4, PGOID.float8: return .double
        case PGOID.numeric: return .decimal
        case PGOID.bytea: return .bytes
        case PGOID.date: return .date
        case PGOID.time, PGOID.timetz: return .time
        case PGOID.timestamp, PGOID.timestamptz: return .timestamp
        case PGOID.uuid: return .uuid
        case PGOID.json, PGOID.jsonb: return .json
        default: break
        }
        if textLike.contains(resolved) { return .string }
        guard let info = catalog[resolved] else { return .raw }
        if info.type == "e" { return .string }
        if info.category == "A" { return .array }
        if info.category == "S" { return .string }
        return .raw
    }
}
