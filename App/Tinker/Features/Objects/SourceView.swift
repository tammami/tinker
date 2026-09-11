import DBCore
import DBSQL
import Observation
import SwiftUI

/// Reads the definition of a view or routine from the catalog.
@MainActor
@Observable
public final class SourceController {
    public let object: SourceObject
    public let connectionID: UUID
    public let dialect: SQLDialect

    public private(set) var source: String?
    /// True when the object is a view (not a routine), so it can be designed on the canvas.
    public var isView: Bool { if case .view = object.kind { true } else { false } }
    public private(set) var isLoading = false
    public private(set) var errorText: String?
    /// Something to know before editing, such as why the canvas is not available.
    public private(set) var noticeText: String?

    private let environment: AppEnvironment

    public func notice(_ text: String) { noticeText = text }
    public func clearNotice() { noticeText = nil }

    public init(object: SourceObject, connectionID: UUID, dialect: SQLDialect, environment: AppEnvironment) {
        self.object = object
        self.connectionID = connectionID
        self.dialect = dialect
        self.environment = environment
    }

    public func load(force: Bool = false) async {
        let database =
            switch object.kind {
            case let .view(ref): ref.database
            case let .routine(schema, _, _, _): schema.database
            }
        guard let session = environment.session(for: connectionID, database: database) else {
            errorText = "No session for this connection"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await session.connect()
            let object = object
            switch object.kind {
            case let .view(ref):
                if force { await session.invalidateIntrospection(.viewDefinition(ref)) }
                source = try await session.introspection(.viewDefinition(ref)) { introspector in
                    guard let server = introspector.server else {
                        throw DBError.protocolError("This driver cannot read view definitions")
                    }
                    return try await server.viewDefinition(ref)
                }
            case let .routine(schema, name, signature, kind):
                let key = IntrospectionCache.Key.routineDefinition(schema, name: name, signature: signature)
                if force { await session.invalidateIntrospection(key) }
                source = try await session.introspection(key) { introspector in
                    guard let server = introspector.server else {
                        throw DBError.protocolError("This driver cannot read routine definitions")
                    }
                    return try await server.routineDefinition(
                        in: schema, name: name, signature: signature, kind: kind
                    )
                }
            }
            errorText = nil
        } catch {
            errorText = (error as? DBError)?.errorDescription ?? String(describing: error)
        }
    }

    public func clearError() { errorText = nil }

    public var title: String {
        switch object.kind {
        case let .view(ref): "\(ref.schema).\(ref.name)"
        case let .routine(schema, name, signature, _): "\(schema.schema).\(name)(\(signature))"
        }
    }

    public var icon: String {
        switch object.kind {
        case .view: Icon.view
        case let .routine(_, _, _, kind): kind.symbolName
        }
    }
}

/// A definition tab: the `CREATE` statement, read-only, with a way into the editor.
///
/// Editing happens in a query tab on purpose: a definition is replaced by running a
/// statement, and the query tab is where statements are run, reviewed and kept in history.
public struct SourceView: View {
    @Bindable var controller: SourceController
    let fontName: String
    let fontSize: Double
    let onEditInQuery: (String) -> Void
    /// Reopens a view in the query builder; nil for routines. Hands back the reason when the
    /// canvas cannot show the view, which is then said here, beside Edit in Query Tab.
    var onOpenInBuilder: ((@escaping (String?) -> Void) -> Void)?

    public var body: some View {
        VStack(spacing: 0) {
            PaneBar {
                HStack(spacing: DesignTokens.Spacing.xs + 2) {
                    Image(systemName: controller.icon).foregroundStyle(.purple)
                    Text(controller.title).font(.system(size: DesignTokens.Typography.body, weight: .semibold)).lineLimit(1)
                }
                Badge(text: "READ-ONLY")
                Spacer()
                if controller.isView, let onOpenInBuilder {
                    Button {
                        onOpenInBuilder { reason in
                            if let reason {
                                controller.notice(
                                    "This view cannot be shown on the canvas: \(reason). Edit it as SQL instead.")
                            }
                        }
                    } label: {
                        Label("Open in Query Builder", systemImage: Icon.builder)
                    }
                    .help("Design this view on the visual canvas")
                }
                Button {
                    if let source = controller.source { onEditInQuery(source) }
                } label: {
                    Label("Edit in Query Tab", systemImage: Icon.query)
                }
                .disabled(controller.source == nil)
                .help("Open the definition in a query tab, where it can be changed and run")
                IconButton(icon: Icon.copy, label: "Copy definition") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(controller.source ?? "", forType: .string)
                }
                .disabled(controller.source == nil)
                IconButton(icon: Icon.refresh, label: "Re-read from the server") {
                    Task { await controller.load(force: true) }
                }
            }
            .controlSize(.small)
            Divider()

            if let error = controller.errorText {
                InlineBanner(kind: .error, message: error) { controller.clearError() }
                Divider()
            }
            if let notice = controller.noticeText {
                InlineBanner(kind: .info, message: notice) { controller.clearNotice() }
                Divider()
            }

            if let source = controller.source {
                ReadOnlySQLView(text: source, dialect: controller.dialect, fontName: fontName, fontSize: fontSize)
            } else if controller.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateView(icon: Icon.source, title: "No definition") {
                    Button("Try Again") { Task { await controller.load(force: true) } }
                }
            }
        }
        .task(id: controller.object) { await controller.load() }
    }
}

/// The SQL editor with editing turned off, for showing a definition with highlighting.
struct ReadOnlySQLView: View {
    let text: String
    let dialect: SQLDialect
    let fontName: String
    let fontSize: Double

    var body: some View {
        SQLEditorView(
            text: .constant(text),
            dialect: dialect,
            fontName: fontName,
            fontSize: fontSize,
            isEditable: false
        )
    }
}
