import DBCore
import Foundation

/// Where a map finds a row's location.
///
/// A geometry column is the obvious place, but most tables keep a location as two plain
/// columns — `latitude` and `longitude`, often as text — or as one text column holding
/// both ("-8.5994, 116.0977"). All three reach the map the same way.
public enum MapSource: Sendable, Hashable {
    /// A geometry column: PostGIS, MySQL spatial, or text holding EWKB/WKT.
    case geometry(Int)
    /// Two columns of numbers. The indices are the columns that actually hold latitudes
    /// and longitudes; `swapped` is true when their names said the opposite, which the
    /// map points out rather than hides.
    case pair(latitude: Int, longitude: Int, swapped: Bool)
    /// One text column with both numbers; `longitudeFirst` when the values are written
    /// longitude then latitude.
    case combined(Int, longitudeFirst: Bool)

    /// The grid columns the source reads from.
    public var columns: [Int] {
        switch self {
        case let .geometry(column): [column]
        case let .pair(latitude, longitude, _): [latitude, longitude]
        case let .combined(column, _): [column]
        }
    }

    /// What a picker calls it, from the grid's column names.
    public func title(columnNames: [String]) -> String {
        func name(_ index: Int) -> String { columnNames.indices.contains(index) ? columnNames[index] : "?" }
        switch self {
        case let .geometry(column): return name(column)
        case let .pair(latitude, longitude, _): return "\(name(latitude)), \(name(longitude))"
        case let .combined(column, longitudeFirst):
            return longitudeFirst ? "\(name(column)) (longitude, latitude)" : name(column)
        }
    }
}

/// One row's location as read from a `MapSource`.
public enum MapReading: Sendable, Hashable {
    /// Something to draw. A geometry may still be flagged unplaceable by its SRID.
    case feature(GeoFeature)
    /// No location: NULL, blank, or the `0, 0` that stands in for "not filled in".
    case empty
    /// Text that is not a coordinate or a geometry.
    case unreadable
    /// Numbers, but not ones that fit on the earth (|latitude| > 90, |longitude| > 180).
    case outOfRange
}

/// Turns coordinate text into numbers, however people tend to type it.
///
/// Accepted: `-8.5994`, ` -8.5994 `, `-8,5994` (a decimal comma), `8°35'57.8"S`,
/// `S 8° 35.96'`, and the Indonesian hemispheres `LU`/`LS`/`BT`/`BB`. The result is for
/// placing a pin; the grid keeps showing, and a copy keeps using, the server's own text.
public enum CoordinateText {
    /// The value's text, for any value that carries one; nil for NULL and binary values.
    public static func text(of value: DBValue?) -> String? {
        guard let value, !value.isNull else { return nil }
        switch value {
        case .bytes, .array, .json, .date, .time, .timestamp, .uuid, .bool: return nil
        default:
            guard let text = value.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return nil
            }
            return text.uppercased() == "NULL" ? nil : text
        }
    }

    /// One coordinate: a plain decimal number, or degrees/minutes/seconds.
    public static func number(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let plain = plainNumber(trimmed) { return plain }
        return degrees(trimmed)
    }

    /// Both coordinates from one piece of text, in the order they are written.
    ///
    /// Separators tried, most specific first: `;`, a comma followed by a space (so decimal
    /// commas survive: `-8,5994, 116,0977`), a lone comma, then whitespace. Brackets and
    /// parentheses around the pair are ignored.
    public static func pair(_ text: String) -> (first: Double, second: Double)? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.first, let last = trimmed.last, "([".contains(first), ")]".contains(last) {
            trimmed = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard !trimmed.isEmpty else { return nil }
        func split(_ separator: String) -> (Double, Double)? {
            let parts = trimmed.components(separatedBy: separator)
            guard parts.count == 2, let first = number(parts[0]), let second = number(parts[1]) else { return nil }
            return (first, second)
        }
        if trimmed.contains(";") { return split(";") }
        if trimmed.contains(", ") { return split(", ") }
        if trimmed.filter({ $0 == "," }).count == 1, let result = split(",") { return result }
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        if words.count == 2, let first = number(String(words[0])), let second = number(String(words[1])) {
            return (first, second)
        }
        return nil
    }

    /// `-8.5994`, `+116.1`, `-8,5994`. No thousands separators, exponents or words:
    /// anything else is not a coordinate someone typed.
    static func plainNumber(_ text: String) -> Double? {
        guard text.allSatisfy({ $0.isASCII && ($0.isNumber || "+-.,".contains($0)) }),
            text.contains(where: \.isNumber)
        else { return nil }
        var normalised = text
        let commas = text.filter { $0 == "," }.count
        if commas > 0 {
            guard commas == 1, !text.contains(".") else { return nil }
            normalised = text.replacingOccurrences(of: ",", with: ".")
        }
        guard let value = Double(normalised), value.isFinite else { return nil }
        return value
    }

    /// Hemisphere markers, longest first so `LS` is not read as a bare `S`. The flag is
    /// true for the ones that make the number negative.
    private static let hemispheres: [(String, Bool)] = [
        ("LU", false), ("LS", true), ("BT", false), ("BB", true),
        ("N", false), ("S", true), ("E", false), ("W", true),
    ]

    /// Degrees, minutes and seconds with a degree sign or a hemisphere to say so;
    /// `8 35 57` alone could be anything and is refused.
    static func degrees(_ text: String) -> Double? {
        var body = text.uppercased()
        var negative = false
        var marked = false
        for (marker, isNegative) in hemispheres {
            if body.hasSuffix(marker) {
                body.removeLast(marker.count)
            } else if body.hasPrefix(marker) {
                body.removeFirst(marker.count)
            } else {
                continue
            }
            negative = isNegative
            marked = true
            break
        }
        let symbols: Set<Character> = ["°", "º", "'", "\"", "′", "″", "’", "”"]
        if body.contains(where: { $0 == "°" || $0 == "º" }) { marked = true }
        guard marked else { return nil }
        let pieces = String(body.map { symbols.contains($0) ? " " : $0 })
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard (1 ... 3).contains(pieces.count) else { return nil }
        var parts: [Double] = []
        for (index, piece) in pieces.enumerated() {
            guard let value = plainNumber(piece) else { return nil }
            // Only the degrees carry a sign; minutes and seconds are below sixty.
            if index > 0, value < 0 || value >= 60 { return nil }
            parts.append(value)
        }
        let isSigned = parts[0] < 0 || pieces[0].hasPrefix("-")
        var magnitude = abs(parts[0])
        if parts.count > 1 { magnitude += parts[1] / 60 }
        if parts.count > 2 { magnitude += parts[2] / 3_600 }
        return negative || isSigned ? -magnitude : magnitude
    }
}

/// What a column's name says about coordinates.
public enum CoordinateNames {
    public enum Axis: Sendable, Hashable {
        case latitude, longitude
    }

    static let latitudeWords: Set<String> = ["lat", "latt", "latitude", "lattitude", "latitud", "lintang"]
    static let longitudeWords: Set<String> = [
        "lng", "lon", "long", "longi", "longitude", "longtitude", "longitud", "bujur",
    ]
    /// Names that hold both numbers in one column.
    static let combinedWords: Set<String> = [
        "latlng", "latlon", "latlong", "lnglat", "lonlat", "coord", "coords", "coordinate", "coordinates",
        "koordinat", "location", "lokasi", "gps", "geolocation", "geo", "position", "posisi", "titik",
    ]

    /// The column's words: `pickupLat`, `pickup_lat` and `Pickup Lat` all read as
    /// `pickup lat`; `lat2` reads as `lat 2`.
    static func words(_ name: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previous: Character?
        for character in name {
            let breaks =
                !character.isLetter && !character.isNumber
                || (previous.map { $0.isLowercase && character.isUppercase } ?? false)
                || (previous.map { $0.isLetter != character.isLetter } ?? false)
            if breaks, !current.isEmpty {
                words.append(current.lowercased())
                current = ""
            }
            if character.isLetter || character.isNumber { current.append(character) }
            previous = character
        }
        if !current.isEmpty { words.append(current.lowercased()) }
        return words
    }

    /// The axis a column's name claims and what is left of the name without it — the key
    /// that pairs `pickup_lat` with `pickup_lng`. Nil for a name that claims neither, or
    /// both.
    public static func axis(of name: String) -> (axis: Axis, key: String)? {
        let words = words(name)
        let latitude = words.indices.filter { latitudeWords.contains(words[$0]) }
        let longitude = words.indices.filter { longitudeWords.contains(words[$0]) }
        let axis: Axis
        let index: Int
        switch (latitude.count, longitude.count) {
        case (1, 0): (axis, index) = (.latitude, latitude[0])
        case (0, 1): (axis, index) = (.longitude, longitude[0])
        default: return nil
        }
        var rest = words
        rest.remove(at: index)
        return (axis, rest.joined(separator: "_"))
    }

    /// Whether the name suggests one column holding both numbers.
    public static func isCombined(_ name: String) -> Bool {
        let words = words(name)
        if words.contains(where: combinedWords.contains) { return true }
        return words.contains(where: latitudeWords.contains) && words.contains(where: longitudeWords.contains)
    }
}

/// Finds and reads the places in a grid: geometry columns, latitude/longitude pairs and
/// combined coordinate columns.
///
/// Works on column metadata plus a value lookup, so it serves a table tab, a query result
/// and a test alike. Only a handful of rows are sampled, which keeps it cheap enough to
/// run on every right-click.
public enum MapSourceDetector {
    /// Rows looked at from the top of the grid, and how many with a value are enough.
    static let rowsScanned = 24
    static let samplesWanted = 8

    /// Every source the grid offers, geometry first, then pairs in column order, then
    /// combined columns.
    public static func detect(
        columns: [ColumnMeta], rowCount: Int, dialect: SQLDialect, value: (_ row: Int, _ column: Int) -> DBValue?
    ) -> [MapSource] {
        let scanned = min(rowCount, rowsScanned)
        var sources: [MapSource] = []
        var used: Set<Int> = []

        for (index, column) in columns.enumerated() where isGeometry(column, index, scanned, dialect, value) {
            sources.append(.geometry(index))
            used.insert(index)
        }

        // Pairs: a latitude and a longitude column whose names agree on everything else.
        var latitudes: [(index: Int, key: String)] = []
        var longitudes: [(index: Int, key: String)] = []
        for (index, column) in columns.enumerated() where !used.contains(index) && canHoldNumber(column.kind) {
            guard case let (axis, key)? = CoordinateNames.axis(of: column.name) else { continue }
            if axis == .latitude { latitudes.append((index, key)) } else { longitudes.append((index, key)) }
        }
        for latitude in latitudes {
            guard let longitude = longitudes.first(where: { $0.key == latitude.key && !used.contains($0.index) }),
                let orientation = pairOrientation(latitude.index, longitude.index, scanned, value)
            else { continue }
            sources.append(
                orientation == .asNamed
                    ? .pair(latitude: latitude.index, longitude: longitude.index, swapped: false)
                    : .pair(latitude: longitude.index, longitude: latitude.index, swapped: true))
            used.formUnion([latitude.index, longitude.index])
        }

        for (index, column) in columns.enumerated()
        where !used.contains(index) && (column.kind == .string || column.kind == .raw)
            && CoordinateNames.isCombined(column.name)
        {
            if let longitudeFirst = combinedOrder(index, scanned, value) {
                sources.append(.combined(index, longitudeFirst: longitudeFirst))
            }
        }
        return sources
    }

    /// The source a right-click on `column` means: the one that reads that column, or else
    /// the grid's first.
    public static func source(for column: Int, among sources: [MapSource]) -> MapSource? {
        sources.first { $0.columns.contains(column) } ?? sources.first
    }

    /// Reads one row's location.
    public static func read(
        _ source: MapSource, dialect: SQLDialect, value: (_ column: Int) -> DBValue?
    ) -> MapReading {
        switch source {
        case let .geometry(column):
            guard let cell = value(column), !cell.isNull else { return .empty }
            if case let .string(text) = cell, text.trimmingCharacters(in: .whitespaces).isEmpty { return .empty }
            return GeometryParser.parse(cell, dialect: dialect).map(MapReading.feature) ?? .unreadable
        case let .pair(latitudeColumn, longitudeColumn, _):
            let latitudeText = CoordinateText.text(of: value(latitudeColumn))
            let longitudeText = CoordinateText.text(of: value(longitudeColumn))
            guard let latitudeText, let longitudeText else {
                return latitudeText == nil && longitudeText == nil ? .empty : .unreadable
            }
            guard let latitude = CoordinateText.number(latitudeText),
                let longitude = CoordinateText.number(longitudeText)
            else { return .unreadable }
            return place(latitude: latitude, longitude: longitude)
        case let .combined(column, longitudeFirst):
            guard let text = CoordinateText.text(of: value(column)) else { return .empty }
            guard case let (first, second)? = CoordinateText.pair(text) else { return .unreadable }
            return longitudeFirst
                ? place(latitude: second, longitude: first) : place(latitude: first, longitude: second)
        }
    }

    /// The row's coordinates as text, `latitude, longitude`, for a pin's subtitle and for
    /// Copy Coordinates. Pairs and combined columns keep the server's own digits; a
    /// geometry point is written from its numbers.
    public static func coordinateText(
        _ source: MapSource, dialect: SQLDialect, value: (_ column: Int) -> DBValue?
    ) -> String? {
        switch source {
        case let .pair(latitude, longitude, _):
            guard let latitudeText = CoordinateText.text(of: value(latitude)),
                let longitudeText = CoordinateText.text(of: value(longitude))
            else { return nil }
            return "\(latitudeText), \(longitudeText)"
        case let .combined(column, longitudeFirst):
            guard let text = CoordinateText.text(of: value(column)) else { return nil }
            guard longitudeFirst, case let (first, second)? = CoordinateText.pair(text) else { return text }
            return "\(GeoShape.format(second)), \(GeoShape.format(first))"
        case .geometry:
            guard case let .feature(feature) = read(source, dialect: dialect, value: value),
                !feature.isUnplaceable, case let .point(point) = feature.shape
            else { return nil }
            return "\(GeoShape.format(point.latitude)), \(GeoShape.format(point.longitude))"
        }
    }

    /// The column whose value names a row on the map: `name`, `title`, `label`, `nama`,
    /// then any column with one of those words in it (`nama_pelanggan`).
    public static func labelColumn(columnNames: [String]) -> Int? {
        let exact: Set<String> = ["name", "title", "label", "nama", "judul"]
        if let index = columnNames.firstIndex(where: { exact.contains($0.lowercased()) }) { return index }
        return columnNames.firstIndex { name in
            CoordinateNames.words(name).contains { exact.contains($0) }
        }
    }

    // MARK: - Sampling

    private static func canHoldNumber(_ kind: DBValueKind) -> Bool {
        switch kind {
        case .int, .uint, .double, .decimal, .string, .raw: true
        default: false
        }
    }

    private static func isGeometry(
        _ column: ColumnMeta, _ index: Int, _ scanned: Int, _ dialect: SQLDialect,
        _ value: (Int, Int) -> DBValue?
    ) -> Bool {
        if GeometryParser.isGeometryType(column.nativeTypeName) { return true }
        // A text column is a geometry column when its first values say so.
        guard column.kind == .string || column.kind == .raw else { return false }
        var sampled = 0
        var parsed = 0
        for row in 0 ..< scanned {
            guard let cell = value(row, index), !cell.isNull else { continue }
            sampled += 1
            if GeometryParser.parse(cell, dialect: dialect) != nil { parsed += 1 }
            if sampled == 4 { break }
        }
        return sampled > 0 && parsed == sampled
    }

    private enum Orientation { case asNamed, swapped }

    /// Whether a named pair really holds coordinates, and which way round. The names
    /// already make the case, so a stray bad value does not sink it: most samples must
    /// read as numbers. A pair with no values yet is taken on its names.
    private static func pairOrientation(
        _ latitude: Int, _ longitude: Int, _ scanned: Int, _ value: (Int, Int) -> DBValue?
    ) -> Orientation? {
        var good = 0
        var bad = 0
        var asNamed = 0
        var swapped = 0
        for row in 0 ..< scanned where good + bad < samplesWanted {
            let latitudeText = CoordinateText.text(of: value(row, latitude))
            let longitudeText = CoordinateText.text(of: value(row, longitude))
            if latitudeText == nil, longitudeText == nil { continue }
            guard let latitudeText, let longitudeText, let a = CoordinateText.number(latitudeText),
                let b = CoordinateText.number(longitudeText)
            else {
                bad += 1
                continue
            }
            if a == 0, b == 0 { continue }
            good += 1
            if abs(a) <= 90, abs(b) <= 180 { asNamed += 1 }
            if abs(b) <= 90, abs(a) <= 180 { swapped += 1 }
        }
        if good == 0, bad == 0 { return .asNamed }
        guard good > bad else { return nil }
        if asNamed == good { return .asNamed }
        if swapped == good { return .swapped }
        // Mixed: read as named and let the out-of-range rows be counted on the map.
        return asNamed > 0 ? .asNamed : nil
    }

    /// For a combined column: nil when it is not coordinates, else whether longitude comes
    /// first. Latitude first is the usual way (it is what map apps copy), so only values
    /// that cannot be latitudes turn it around.
    private static func combinedOrder(_ column: Int, _ scanned: Int, _ value: (Int, Int) -> DBValue?) -> Bool? {
        var good = 0
        var bad = 0
        var latitudeFirst = 0
        var longitudeFirst = 0
        for row in 0 ..< scanned where good + bad < samplesWanted {
            guard let text = CoordinateText.text(of: value(row, column)) else { continue }
            guard case let (first, second)? = CoordinateText.pair(text) else {
                bad += 1
                continue
            }
            if first == 0, second == 0 { continue }
            good += 1
            if abs(first) <= 90, abs(second) <= 180 { latitudeFirst += 1 }
            if abs(second) <= 90, abs(first) <= 180 { longitudeFirst += 1 }
        }
        guard good > 0, good > bad else { return nil }
        if latitudeFirst == good { return false }
        if longitudeFirst == good { return true }
        return latitudeFirst > 0 ? false : nil
    }

    private static func place(latitude: Double, longitude: Double) -> MapReading {
        if latitude == 0, longitude == 0 { return .empty }
        let point = GeoPoint(longitude: longitude, latitude: latitude)
        guard point.isValid else { return .outOfRange }
        return .feature(GeoFeature(shape: .point(point), srid: 4326))
    }
}

extension GeoShape {
    /// One spot that stands for the shape: the point itself, or the middle of its extent.
    public var anchor: GeoPoint? {
        if case let .point(point) = self { return point }
        guard let bounds else { return nil }
        return GeoPoint(
            longitude: (bounds.minLongitude + bounds.maxLongitude) / 2,
            latitude: (bounds.minLatitude + bounds.maxLatitude) / 2)
    }
}
