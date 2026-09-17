import DBCore
import DBSQL
import Foundation
import NIOCore
import PostgresNIO

/// A parameter sent as text with an unspecified type OID, so the server infers the type
/// from where the placeholder sits.
///
/// Binding every value this way keeps one code path for all types and makes the server,
/// rather than the driver, responsible for coercion — which is what makes generated DML
/// type-safe without the driver having to model every target type (SPEC §7.1).
struct PostgresTextParameter: PostgresDynamicTypeEncodable {
    let text: String

    /// OID 0 means "unspecified"; PostgreSQL then infers the parameter's type.
    var psqlType: PostgresDataType { PostgresDataType(0) }
    var psqlFormat: PostgresFormat { .text }

    func encode<JSONEncoder: PostgresJSONEncoder>(
        into byteBuffer: inout ByteBuffer,
        context: PostgresEncodingContext<JSONEncoder>
    ) {
        byteBuffer.writeString(text)
    }
}

/// Renders ``DBValue`` into the text PostgreSQL accepts as parameter input.
enum PostgresParameterEncoder {
    static func bindings(for values: [DBValue]) -> PostgresBindings {
        var bindings = PostgresBindings(capacity: values.count)
        for value in values {
            if case .null = value {
                bindings.appendNull()
            } else {
                bindings.append(PostgresTextParameter(text: text(for: value)))
            }
        }
        return bindings
    }

    /// The value in PostgreSQL's input text format.
    static func text(for value: DBValue) -> String {
        switch value {
        case .null:
            return ""
        case let .bool(flag):
            return flag ? "t" : "f"
        case let .bytes(data):
            return "\\x" + data.map { String(format: "%02x", $0) }.joined()
        case let .array(items):
            return arrayLiteral(items)
        case let .raw(_, text, bytes):
            if let text { return text }
            if let bytes { return "\\x" + bytes.map { String(format: "%02x", $0) }.joined() }
            return ""
        default:
            return value.text ?? ""
        }
    }

    /// `{a,b,NULL}`, through the one implementation of the quoting rule.
    static func arrayLiteral(_ items: [DBValue]) -> String {
        SQLLiteral.postgresArray(items, elementText: text(for:))
    }
}
