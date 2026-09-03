import DBCore
import Foundation
import MySQLNIO
import NIOCore

/// Renders ``DBValue`` into MySQL bind parameters.
///
/// Everything is bound as a string, so the server does the coercion and one path covers
/// every type — the same choice the PostgreSQL driver makes, for the same reason
/// (SPEC §7.1, DECISIONS.md ADR-0011).
enum MySQLParameterEncoder {
    static func bindings(for values: [DBValue]) -> [MySQLData] {
        values.map { value in
            switch value {
            case .null:
                return MySQLData(type: .null, format: .binary, buffer: nil, isUnsigned: false)
            case let .bytes(data):
                var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                buffer.writeBytes(data)
                return MySQLData(type: .blob, format: .binary, buffer: buffer, isUnsigned: false)
            default:
                return MySQLData(string: text(for: value))
            }
        }
    }

    /// The value in the text form MySQL parses.
    static func text(for value: DBValue) -> String {
        switch value {
        case .bool(let flag): flag ? "1" : "0"
        case let .array(items): "[" + items.map { $0.text ?? "null" }.joined(separator: ",") + "]"
        case let .raw(_, text, bytes):
            text ?? bytes.map { data in data.map { String(format: "%02x", $0) }.joined() } ?? ""
        default: value.text ?? ""
        }
    }
}
