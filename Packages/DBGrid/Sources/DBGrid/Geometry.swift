import DBCore
import Foundation

/// A longitude/latitude pair, the only coordinate a map can draw.
public struct GeoPoint: Sendable, Hashable {
    public var longitude: Double
    public var latitude: Double

    public init(longitude: Double, latitude: Double) {
        self.longitude = longitude
        self.latitude = latitude
    }

    public var isValid: Bool {
        longitude.isFinite && latitude.isFinite && abs(longitude) <= 180 && abs(latitude) <= 90
    }
}

/// The lon/lat extent of a shape, for fitting the map to it.
public struct GeoBounds: Sendable, Hashable {
    public var minLongitude: Double
    public var minLatitude: Double
    public var maxLongitude: Double
    public var maxLatitude: Double

    public init(_ point: GeoPoint) {
        minLongitude = point.longitude
        maxLongitude = point.longitude
        minLatitude = point.latitude
        maxLatitude = point.latitude
    }

    public mutating func include(_ point: GeoPoint) {
        minLongitude = min(minLongitude, point.longitude)
        maxLongitude = max(maxLongitude, point.longitude)
        minLatitude = min(minLatitude, point.latitude)
        maxLatitude = max(maxLatitude, point.latitude)
    }

    public mutating func include(_ other: GeoBounds) {
        include(GeoPoint(longitude: other.minLongitude, latitude: other.minLatitude))
        include(GeoPoint(longitude: other.maxLongitude, latitude: other.maxLatitude))
    }
}

/// A geometry in the shapes a map draws: points, lines and rings, alone or in groups.
public indirect enum GeoShape: Sendable, Hashable {
    case point(GeoPoint)
    case line([GeoPoint])
    /// The first ring is the outer boundary; the rest are holes.
    case polygon([[GeoPoint]])
    case multiPoint([GeoPoint])
    case multiLine([[GeoPoint]])
    case multiPolygon([[[GeoPoint]]])
    case collection([GeoShape])

    /// The extent, or nil for an empty shape.
    public var bounds: GeoBounds? {
        var result: GeoBounds?
        func add(_ point: GeoPoint) {
            if result == nil { result = GeoBounds(point) } else { result?.include(point) }
        }
        switch self {
        case let .point(point): add(point)
        case let .line(points), let .multiPoint(points): points.forEach(add)
        case let .polygon(rings), let .multiLine(rings): rings.joined().forEach(add)
        case let .multiPolygon(polygons): polygons.joined().joined().forEach(add)
        case let .collection(shapes):
            for shape in shapes {
                if let inner = shape.bounds { result == nil ? (result = inner) : result?.include(inner) }
            }
        }
        return result
    }

    /// How many vertices the shape holds, which is what decides how it is drawn and cut.
    public var vertexCount: Int {
        switch self {
        case .point: 1
        case let .line(points), let .multiPoint(points): points.count
        case let .polygon(rings), let .multiLine(rings): rings.reduce(0) { $0 + $1.count }
        case let .multiPolygon(polygons): polygons.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } }
        case let .collection(shapes): shapes.reduce(0) { $0 + $1.vertexCount }
        }
    }

    public var typeName: String {
        switch self {
        case .point: "POINT"
        case .line: "LINESTRING"
        case .polygon: "POLYGON"
        case .multiPoint: "MULTIPOINT"
        case .multiLine: "MULTILINESTRING"
        case .multiPolygon: "MULTIPOLYGON"
        case .collection: "GEOMETRYCOLLECTION"
        }
    }

    /// Well-known text. Coordinates are written with up to six decimals.
    public var wkt: String {
        func coordinate(_ point: GeoPoint) -> String {
            "\(Self.format(point.longitude)) \(Self.format(point.latitude))"
        }
        func ring(_ points: [GeoPoint]) -> String { "(" + points.map(coordinate).joined(separator: ", ") + ")" }
        switch self {
        case let .point(point): return "POINT(\(coordinate(point)))"
        case let .line(points): return "LINESTRING\(ring(points))"
        case let .polygon(rings): return "POLYGON(" + rings.map(ring).joined(separator: ", ") + ")"
        case let .multiPoint(points): return "MULTIPOINT\(ring(points))"
        case let .multiLine(lines): return "MULTILINESTRING(" + lines.map(ring).joined(separator: ", ") + ")"
        case let .multiPolygon(polygons):
            return "MULTIPOLYGON("
                + polygons.map { "(" + $0.map(ring).joined(separator: ", ") + ")" }.joined(separator: ", ") + ")"
        case let .collection(shapes): return "GEOMETRYCOLLECTION(" + shapes.map(\.wkt).joined(separator: ", ") + ")"
        }
    }

    /// One line for a grid cell: the whole WKT for a point, a count for anything bigger.
    public var summary: String {
        switch self {
        case .point: wkt
        default: "\(typeName) · \(vertexCount) vertices"
        }
    }

    static func format(_ value: Double) -> String {
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }
}

/// A parsed geometry with what the map needs to know about its coordinates.
public struct GeoFeature: Sendable, Hashable {
    public var shape: GeoShape
    public var srid: Int?
    /// True when the coordinates were not longitude/latitude to begin with and could not
    /// be converted, so the map cannot place them.
    public var isUnplaceable: Bool

    public init(shape: GeoShape, srid: Int?, isUnplaceable: Bool = false) {
        self.shape = shape
        self.srid = srid
        self.isUnplaceable = isUnplaceable
    }
}

/// Reads PostGIS EWKB (bytes or hex text), MySQL's SRID-prefixed WKB, and WKT.
///
/// PostGIS hands a geometry column over as EWKB; MySQL as four bytes of SRID followed by
/// WKB. Both are decoded with one reader, and both store longitude then latitude in the
/// binary (MySQL's latitude-first order is a property of its WKT, not of its bytes).
/// SRID 3857 is unprojected to longitude/latitude; 4326 is used as is; any other SRID is
/// kept if its numbers look like degrees and flagged as unplaceable otherwise.
public enum GeometryParser {
    /// Whether a column's native type carries geometry.
    public static func isGeometryType(_ nativeType: String) -> Bool {
        let lowered = nativeType.lowercased()
        return [
            "geometry", "geography", "point", "linestring", "polygon", "multipoint", "multilinestring",
            "multipolygon", "geometrycollection", "geomcollection",
        ].contains { lowered.hasPrefix($0) }
    }

    public static func parse(_ value: DBValue, dialect: SQLDialect) -> GeoFeature? {
        switch value {
        case let .raw(typeName, text, bytes):
            if let bytes, !bytes.isEmpty { return parse(bytes: bytes, dialect: dialect) }
            if let text { return parse(text: text, dialect: dialect) }
            _ = typeName
            return nil
        case let .bytes(data):
            return parse(bytes: data, dialect: dialect)
        case let .string(text):
            return parse(text: text, dialect: dialect)
        default:
            return nil
        }
    }

    /// Hex EWKB (PostGIS's text form) or WKT, optionally `SRID=n;` prefixed.
    public static func parse(text: String, dialect: SQLDialect) -> GeoFeature? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.allSatisfy(\.isHexDigit), trimmed.count % 2 == 0, trimmed.count >= 18, let data = Data(hex: trimmed)
        {
            return parse(bytes: data, dialect: dialect)
        }
        var reader = WKTReader(trimmed)
        return reader.read().map { place($0.shape, srid: $0.srid, dialect: dialect) }
    }

    public static func parse(bytes: Data, dialect: SQLDialect) -> GeoFeature? {
        var reader = WKBReader(bytes)
        var srid: Int?
        if dialect == .mysql {
            // MySQL: SRID (little-endian, 4 bytes) then plain WKB.
            guard bytes.count > 4 else { return nil }
            reader.littleEndian = true
            srid = Int(reader.readUInt32() ?? 0)
        }
        guard let shape = reader.readGeometry(srid: &srid) else { return nil }
        return place(shape, srid: srid, dialect: dialect)
    }

    /// Turns the shape's coordinates into longitude/latitude where that is possible.
    static func place(_ shape: GeoShape, srid: Int?, dialect: SQLDialect) -> GeoFeature {
        switch srid {
        case 3857, 900913:
            return GeoFeature(shape: shape.mapped(unproject3857), srid: srid)
        case 4326:
            return GeoFeature(shape: shape, srid: srid)
        case nil, 0:
            return GeoFeature(shape: shape, srid: srid, isUnplaceable: !shape.looksLikeDegrees)
        default:
            return GeoFeature(shape: shape, srid: srid, isUnplaceable: !shape.looksLikeDegrees)
        }
    }

    static func unproject3857(_ point: GeoPoint) -> GeoPoint {
        let radius = 6_378_137.0
        let longitude = point.longitude / radius * 180 / .pi
        let latitude = (2 * atan(exp(point.latitude / radius)) - .pi / 2) * 180 / .pi
        return GeoPoint(longitude: longitude, latitude: latitude)
    }
}

extension GeoShape {
    func mapped(_ transform: (GeoPoint) -> GeoPoint) -> GeoShape {
        switch self {
        case let .point(point): .point(transform(point))
        case let .line(points): .line(points.map(transform))
        case let .polygon(rings): .polygon(rings.map { $0.map(transform) })
        case let .multiPoint(points): .multiPoint(points.map(transform))
        case let .multiLine(lines): .multiLine(lines.map { $0.map(transform) })
        case let .multiPolygon(polygons): .multiPolygon(polygons.map { $0.map { $0.map(transform) } })
        case let .collection(shapes): .collection(shapes.map { $0.mapped(transform) })
        }
    }

    var looksLikeDegrees: Bool {
        guard let bounds else { return true }
        return abs(bounds.minLongitude) <= 180 && abs(bounds.maxLongitude) <= 180
            && abs(bounds.minLatitude) <= 90 && abs(bounds.maxLatitude) <= 90
    }
}

/// A cursor over WKB/EWKB bytes.
struct WKBReader {
    let data: Data
    var offset: Data.Index
    var littleEndian = true

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    private static let zFlag: UInt32 = 0x8000_0000
    private static let mFlag: UInt32 = 0x4000_0000
    private static let sridFlag: UInt32 = 0x2000_0000

    mutating func readUInt8() -> UInt8? {
        guard offset < data.endIndex else { return nil }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt32() -> UInt32? {
        guard offset + 4 <= data.endIndex else { return nil }
        var value: UInt32 = 0
        for index in 0 ..< 4 {
            let byte = UInt32(data[offset + index])
            value |= littleEndian ? byte << (8 * UInt32(index)) : byte << (8 * UInt32(3 - index))
        }
        offset += 4
        return value
    }

    mutating func readDouble() -> Double? {
        guard offset + 8 <= data.endIndex else { return nil }
        var bits: UInt64 = 0
        for index in 0 ..< 8 {
            let byte = UInt64(data[offset + index])
            bits |= littleEndian ? byte << (8 * UInt64(index)) : byte << (8 * UInt64(7 - index))
        }
        offset += 8
        let value = Double(bitPattern: bits)
        return value.isFinite ? value : nil
    }

    /// One geometry, including nested ones; `srid` is filled in from an EWKB header.
    mutating func readGeometry(srid: inout Int?) -> GeoShape? {
        guard let order = readUInt8() else { return nil }
        littleEndian = order == 1
        guard var type = readUInt32() else { return nil }
        let hasZ = type & Self.zFlag != 0
        let hasM = type & Self.mFlag != 0
        if type & Self.sridFlag != 0 {
            guard let value = readUInt32() else { return nil }
            srid = Int(value)
        }
        type &= 0x0FFF_FFFF
        // ISO WKB spells Z/M as 1000/2000/3000 added to the type.
        let extraDimensions = (hasZ ? 1 : 0) + (hasM ? 1 : 0) + (type >= 3000 ? 2 : type >= 1000 ? 1 : 0)
        type %= 1000

        func readPoint() -> GeoPoint? {
            guard let x = readDouble(), let y = readDouble() else { return nil }
            for _ in 0 ..< extraDimensions { guard readDouble() != nil else { return nil } }
            return GeoPoint(longitude: x, latitude: y)
        }
        func readRing() -> [GeoPoint]? {
            guard let count = readUInt32(), count <= 1_000_000 else { return nil }
            var points: [GeoPoint] = []
            points.reserveCapacity(Int(count))
            for _ in 0 ..< count { guard let point = readPoint() else { return nil }; points.append(point) }
            return points
        }
        func readMany<T>(_ each: (inout WKBReader, inout Int?) -> T?) -> [T]? {
            guard let count = readUInt32(), count <= 100_000 else { return nil }
            var items: [T] = []
            items.reserveCapacity(Int(count))
            for _ in 0 ..< count { guard let item = each(&self, &srid) else { return nil }; items.append(item) }
            return items
        }

        switch type {
        case 1:
            guard let point = readPoint() else { return nil }
            return .point(point)
        case 2:
            guard let points = readRing() else { return nil }
            return .line(points)
        case 3:
            guard let count = readUInt32(), count <= 100_000 else { return nil }
            var rings: [[GeoPoint]] = []
            for _ in 0 ..< count { guard let ring = readRing() else { return nil }; rings.append(ring) }
            return .polygon(rings)
        case 4:
            guard
                let items = readMany({ reader, srid -> GeoPoint? in
                    if case let .point(point)? = reader.readGeometry(srid: &srid) { return point }
                    return nil
                })
            else { return nil }
            return .multiPoint(items)
        case 5:
            guard
                let items = readMany({ reader, srid -> [GeoPoint]? in
                    if case let .line(points)? = reader.readGeometry(srid: &srid) { return points }
                    return nil
                })
            else { return nil }
            return .multiLine(items)
        case 6:
            guard
                let items = readMany({ reader, srid -> [[GeoPoint]]? in
                    if case let .polygon(rings)? = reader.readGeometry(srid: &srid) { return rings }
                    return nil
                })
            else { return nil }
            return .multiPolygon(items)
        case 7:
            guard let items = readMany({ reader, srid -> GeoShape? in reader.readGeometry(srid: &srid) }) else {
                return nil
            }
            return .collection(items)
        default:
            return nil
        }
    }
}

/// Reads well-known text: `SRID=4326;POINT(106.8 -6.2)`, `LINESTRING(...)`, and the rest.
struct WKTReader {
    private let text: String
    private var index: String.Index

    init(_ text: String) {
        self.text = text
        index = text.startIndex
    }

    mutating func read() -> (shape: GeoShape, srid: Int?)? {
        var srid: Int?
        if text.uppercased().hasPrefix("SRID=") {
            guard let semicolon = text.firstIndex(of: ";") else { return nil }
            srid = Int(text[text.index(text.startIndex, offsetBy: 5) ..< semicolon])
            index = text.index(after: semicolon)
        }
        return readShape().map { ($0, srid) }
    }

    private mutating func skipSpaces() {
        while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
    }

    private mutating func readWord() -> String {
        skipSpaces()
        var word = ""
        while index < text.endIndex, text[index].isLetter { word.append(text[index]); index = text.index(after: index) }
        return word.uppercased()
    }

    private mutating func expect(_ character: Character) -> Bool {
        skipSpaces()
        guard index < text.endIndex, text[index] == character else { return false }
        index = text.index(after: index)
        return true
    }

    private mutating func readNumber() -> Double? {
        skipSpaces()
        let start = index
        while index < text.endIndex, "+-.0123456789eE".contains(text[index]) { index = text.index(after: index) }
        return Double(text[start ..< index])
    }

    private mutating func readPoint() -> GeoPoint? {
        guard let x = readNumber(), let y = readNumber() else { return nil }
        // Z and M, if present, are skipped.
        var probe = index
        while probe < text.endIndex, text[probe].isWhitespace { probe = text.index(after: probe) }
        while probe < text.endIndex, "+-.0123456789eE".contains(text[probe]) {
            _ = readNumber()
            probe = index
            while probe < text.endIndex, text[probe].isWhitespace { probe = text.index(after: probe) }
        }
        return GeoPoint(longitude: x, latitude: y)
    }

    private mutating func readPointList() -> [GeoPoint]? {
        guard expect("(") else { return nil }
        var points: [GeoPoint] = []
        repeat {
            guard let point = readPoint() else { return nil }
            points.append(point)
        } while expect(",")
        return expect(")") ? points : nil
    }

    private mutating func readRings() -> [[GeoPoint]]? {
        guard expect("(") else { return nil }
        var rings: [[GeoPoint]] = []
        repeat {
            guard let ring = readPointList() else { return nil }
            rings.append(ring)
        } while expect(",")
        return expect(")") ? rings : nil
    }

    private mutating func readShape() -> GeoShape? {
        var word = readWord()
        // Dimension markers such as `POINT Z` are accepted and ignored.
        if ["Z", "M", "ZM"].contains(readWordIfDimension()) { word = word.replacingOccurrences(of: " ", with: "") }
        switch word {
        case "POINT":
            guard expect("("), let point = readPoint(), expect(")") else { return nil }
            return .point(point)
        case "LINESTRING":
            return readPointList().map(GeoShape.line)
        case "POLYGON":
            return readRings().map(GeoShape.polygon)
        case "MULTIPOINT":
            guard expect("(") else { return nil }
            var points: [GeoPoint] = []
            repeat {
                skipSpaces()
                let wrapped = index < text.endIndex && text[index] == "("
                if wrapped { _ = expect("(") }
                guard let point = readPoint() else { return nil }
                if wrapped, !expect(")") { return nil }
                points.append(point)
            } while expect(",")
            return expect(")") ? .multiPoint(points) : nil
        case "MULTILINESTRING":
            return readRings().map(GeoShape.multiLine)
        case "MULTIPOLYGON":
            guard expect("(") else { return nil }
            var polygons: [[[GeoPoint]]] = []
            repeat {
                guard let rings = readRings() else { return nil }
                polygons.append(rings)
            } while expect(",")
            return expect(")") ? .multiPolygon(polygons) : nil
        case "GEOMETRYCOLLECTION":
            guard expect("(") else { return nil }
            var shapes: [GeoShape] = []
            repeat {
                guard let shape = readShape() else { return nil }
                shapes.append(shape)
            } while expect(",")
            return expect(")") ? .collection(shapes) : nil
        default:
            return nil
        }
    }

    private mutating func readWordIfDimension() -> String {
        let saved = index
        let word = readWord()
        if ["Z", "M", "ZM"].contains(word) { return word }
        index = saved
        return ""
    }
}

extension Data {
    /// Bytes from a hex string, or nil when a character is not hex.
    init?(hex: String) {
        var data = Data(capacity: hex.count / 2)
        var high: UInt8?
        for scalar in hex.utf8 {
            let nibble: UInt8
            switch scalar {
            case 48 ... 57: nibble = scalar - 48
            case 65 ... 70: nibble = scalar - 55
            case 97 ... 102: nibble = scalar - 87
            default: return nil
            }
            if let h = high {
                data.append(h << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        guard high == nil else { return nil }
        self = data
    }
}
