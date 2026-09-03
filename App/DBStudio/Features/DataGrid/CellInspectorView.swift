import DBCore
import SwiftUI
import UniformTypeIdentifiers

/// The right-side panel showing the focused cell in full (SPEC §12.5).
public struct CellInspectorView: View {
    let columnName: String
    let nativeType: String
    let value: DBValue?
    let isEditable: Bool
    let onCommit: (String) -> Void

    @State private var draft = ""
    @State private var isExporting = false

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(columnName).font(.headline)
                Text(nativeType).font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            switch value {
            case .none:
                Text("No cell selected").foregroundStyle(.secondary)

            case .null:
                Text("NULL").italic().foregroundStyle(.tertiary)
                if isEditable {
                    Button("Replace with empty text") { onCommit("") }
                }

            case let .bytes(data):
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(data.count) bytes").font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        Text(Self.hexDump(data))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button("Save as File…") { isExporting = true }
                        .fileExporter(
                            isPresented: $isExporting,
                            document: BinaryDocument(data: data),
                            contentType: .data,
                            defaultFilename: columnName
                        ) { _ in }
                }

            case let .json(text):
                VStack(alignment: .leading, spacing: 6) {
                    ScrollView {
                        Text(Self.prettyJSON(text))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button("Copy Formatted") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.prettyJSON(text), forType: .string)
                    }
                }

            case let .some(other):
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $draft)
                        .font(.system(.body, design: .monospaced))
                        .disabled(!isEditable)
                        .frame(minHeight: 120)
                    HStack {
                        Text("\(draft.count) characters")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if isEditable {
                            Button("Apply") { onCommit(draft) }
                                .disabled(draft == (other.text ?? ""))
                        }
                    }
                }
                .onAppear { draft = other.text ?? "" }
                .onChange(of: other) { _, new in draft = new.text ?? "" }
            }

            Spacer()
        }
        .padding(12)
        .frame(width: DesignTokens.Metrics.inspectorWidth)
    }

    /// Sixteen bytes a line, offset, hex and printable text — the usual shape.
    static func hexDump(_ data: Data, limit: Int = 4_096) -> String {
        var lines: [String] = []
        let bytes = Array(data.prefix(limit))
        for offset in stride(from: 0, to: bytes.count, by: 16) {
            let chunk = Array(bytes[offset ..< min(offset + 16, bytes.count)])
            let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
            let text = String(chunk.map { $0 >= 32 && $0 < 127 ? Character(UnicodeScalar($0)) : "." })
            lines.append(String(format: "%08x  %-47s  %@", offset, (hex as NSString).utf8String ?? "", text))
        }
        if data.count > limit { lines.append("… \(data.count - limit) more bytes") }
        return lines.joined(separator: "\n")
    }

    static func prettyJSON(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(
                  withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
              )
        else { return text }
        return String(decoding: pretty, as: UTF8.self)
    }
}

/// Wraps raw bytes so the cell inspector can offer "Save as File…".
struct BinaryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
