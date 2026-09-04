import DBCore
import Foundation

/// One row in the sidebar tree: groups → connections → databases → schemas → objects.
public struct SidebarItem: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case group(path: [String])
        case connection(UUID)
        case database(connection: UUID, name: String)
        case schema(connection: UUID, ref: SchemaRef)
        case tableFolder(connection: UUID, schema: SchemaRef, kind: TableKind)
        case table(connection: UUID, info: TableInfo)
        case routineFolder(connection: UUID, schema: SchemaRef)
        case routine(connection: UUID, schema: SchemaRef, name: String, signature: String)
        /// Shown while a node's children are being read.
        case loading(parent: String)
        /// Shown when reading a node's children failed, carrying the server's words.
        case failure(parent: String, message: String)
    }

    public let id: String
    public let kind: Kind
    public let title: String
    public var subtitle: String?
    public var symbolName: String
    /// nil for leaves; an empty array means "expandable but not yet loaded".
    public var children: [SidebarItem]?

    public init(
        id: String,
        kind: Kind,
        title: String,
        subtitle: String? = nil,
        symbolName: String,
        children: [SidebarItem]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.children = children
    }

    /// The connection a row belongs to, which is what most commands need.
    public var connectionID: UUID? {
        switch kind {
        case let .connection(id), let .database(id, _), let .schema(id, _),
            let .tableFolder(id, _, _), let .table(id, _),
            let .routineFolder(id, _), let .routine(id, _, _, _):
            id
        case .group, .loading, .failure:
            nil
        }
    }

    /// The table a row points at, for Open and the context menu.
    public var tableRef: TableRef? {
        if case let .table(_, info) = kind { info.ref } else { nil }
    }

    public var isExpandable: Bool { children != nil }

    /// Extracts a connection id from a row id, for restoring selection.
    public static func connectionID(from itemID: SidebarItem.ID) -> UUID? {
        let parts = itemID.split(separator: "/")
        for part in parts {
            if let uuid = UUID(uuidString: String(part)) { return uuid }
        }
        return nil
    }
}
