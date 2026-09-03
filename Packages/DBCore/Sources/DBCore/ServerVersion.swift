import Foundation

/// Which server product is on the other end. Introspection queries branch on this
/// where catalogs differ.
public enum ServerFlavor: String, Sendable, Hashable, Codable, CaseIterable {
    case postgresql, mysql, mariadb, percona, aurora, unknown
}

/// The server's version, parsed and in its original spelling.
public struct ServerVersion: Sendable, Hashable, Codable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let flavor: ServerFlavor
    /// The version string exactly as the server reported it.
    public let rawString: String

    public init(major: Int, minor: Int, patch: Int, flavor: ServerFlavor, rawString: String) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.flavor = flavor
        self.rawString = rawString
    }

    public var description: String { "\(flavor.rawValue) \(major).\(minor).\(patch)" }

    /// True when the server is at least the given version.
    public func isAtLeast(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) -> Bool {
        (self.major, self.minor, self.patch) >= (major, minor, patch)
    }

    /// Parses the leading `major[.minor[.patch]]` of a version string.
    /// PostgreSQL 10+ and MySQL both start their version strings with the number.
    public static func parseNumbers(_ text: String) -> (major: Int, minor: Int, patch: Int) {
        var numbers: [Int] = []
        var current = ""
        for character in text {
            if character.isNumber {
                current.append(character)
            } else {
                if !current.isEmpty { numbers.append(Int(current) ?? 0); current = "" }
                if character != "." { break }
            }
        }
        if !current.isEmpty { numbers.append(Int(current) ?? 0) }
        return (
            numbers.count > 0 ? numbers[0] : 0,
            numbers.count > 1 ? numbers[1] : 0,
            numbers.count > 2 ? numbers[2] : 0
        )
    }
}
