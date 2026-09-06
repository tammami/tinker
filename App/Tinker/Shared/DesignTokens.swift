import AppKit
import DBCore
import SwiftUI

/// Every colour, metric, spacing step, icon and font the UI uses.
///
/// One vocabulary for the whole app: a bar is always `Metrics.barHeight` tall and padded
/// by `Spacing.md`, a row's icon is always `Metrics.iconWidth` wide, and every concept has
/// exactly one symbol in `Icon`. Colours map to system semantic colours so dark mode,
/// increased contrast and accessibility settings follow automatically. The only
/// hard-coded colours are the seven connection colours, which are identities rather than
/// theme values.
public enum DesignTokens {
    /// The spacing scale. Nothing in the UI uses a spacing value that is not one of these.
    public enum Spacing {
        /// Between an icon and its text, or two glyphs that belong together.
        public static let xs: CGFloat = 4
        /// Between controls in a bar.
        public static let sm: CGFloat = 8
        /// A bar's horizontal inset; the gap between a bar's groups.
        public static let md: CGFloat = 12
        /// A sheet's inset; the gap between sections.
        public static let lg: CGFloat = 16
        /// Around an empty state or a welcome card.
        public static let xl: CGFloat = 24
    }

    public enum Metrics {
        /// Fixed grid row height. Fixed, not automatic, because uniform heights are what
        /// let the table view scroll a million rows.
        public static let gridRowHeight: CGFloat = 22
        public static let gridHeaderHeight: CGFloat = 24
        public static let minimumColumnWidth: CGFloat = 40
        public static let defaultColumnWidth: CGFloat = 140
        public static let maximumColumnWidth: CGFloat = 1_200
        /// Text longer than this is truncated in a cell; the full value is in the inspector.
        public static let inCellTextLimit = 512
        public static let sidebarMinWidth: CGFloat = 220
        public static let sidebarIdealWidth: CGFloat = 270
        public static let inspectorWidth: CGFloat = 300
        /// The workspace tab strip.
        public static let tabHeight: CGFloat = 34
        /// Every toolbar-like bar inside a pane: editor controls, filter bar, mode bar.
        public static let barHeight: CGFloat = 36
        /// Every status line at the foot of a pane or window.
        public static let statusHeight: CGFloat = 26
        /// The secondary strip that lists a query's results.
        public static let resultTabHeight: CGFloat = 28
        /// The frame every row icon sits in, so text lines up regardless of glyph width.
        public static let iconWidth: CGFloat = 18
        public static let cornerRadius: CGFloat = 6
        public static let smallCornerRadius: CGFloat = 4
        /// Sheet widths, in three sizes only.
        public static let compactSheetWidth: CGFloat = 440
        public static let sheetWidth: CGFloat = 560
        public static let wideSheetWidth: CGFloat = 760
    }

    public enum Colors {
        public static let editedCell = NSColor.systemYellow.withAlphaComponent(0.28)
        public static let insertedRow = NSColor.systemGreen.withAlphaComponent(0.22)
        public static let deletedRow = NSColor.systemRed.withAlphaComponent(0.20)
        public static let nullText = NSColor.tertiaryLabelColor
        public static let binaryText = NSColor.secondaryLabelColor
        public static let productionBadge = NSColor.systemRed

        /// The hairline under the grid's column headings.
        ///
        /// Only the header carries rules. The rows do not: alternating backgrounds already
        /// separate them, and vertical lines through the values read as a cage.
        public static let gridSeparator = NSColor.separatorColor.withAlphaComponent(0.22)

        /// The stripe colour for a connection.
        public static func connection(_ color: ConnectionColor?) -> NSColor {
            switch color {
            case .red: .systemRed
            case .orange: .systemOrange
            case .yellow: .systemYellow
            case .green: .systemGreen
            case .blue: .systemBlue
            case .purple: .systemPurple
            case .gray: .systemGray
            case nil: .clear
            }
        }
    }

    public enum Fonts {
        public static var grid: NSFont {
            NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }

        /// The editor font, from settings, falling back to SF Mono 13.
        public static func editor(name: String = "SF Mono", size: CGFloat = 13) -> NSFont {
            NSFont(name: name, size: size)
                ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }
}

/// Every symbol the app draws, named by what it means rather than by what it looks like.
///
/// A concept has one icon. The sidebar, the tab strip, the command palette and the
/// context menus all draw a table with `Icon.table`, so a person learns each glyph once.
public enum Icon {
    // Objects
    public static let connection = "server.rack"
    public static let database = "cylinder"
    public static let schema = "square.stack.3d.up"
    public static let table = "tablecells"
    public static let view = "eye"
    public static let materializedView = "eye.square"
    public static let foreignTable = "link"
    public static let systemTable = "gearshape"
    public static let partition = "square.split.2x1"
    public static let function = "function"
    public static let procedure = "gearshape.2"
    public static let column = "rectangle.split.3x1"
    public static let index = "list.number"
    public static let foreignKey = "arrow.triangle.branch"
    public static let check = "checkmark.seal"
    public static let trigger = "bolt"
    public static let group = "folder"
    public static let user = "person"
    public static let variable = "slider.horizontal.3"
    public static let activity = "waveform.path.ecg"
    public static let source = "chevron.left.forwardslash.chevron.right"
    public static let builder = "rectangle.connected.to.line.below"
    public static let map = "map"
    public static let transfer = "arrow.left.arrow.right"
    public static let sync = "arrow.triangle.2.circlepath"
    public static let structureSync = "square.grid.3x3.square"
    public static let join = "link"

    // Tabs and panes
    public static let query = "text.alignleft"
    public static let objects = "list.bullet.rectangle"
    public static let structure = "square.grid.3x3"
    public static let data = "tablecells"
    public static let inspector = "sidebar.trailing"
    public static let sidebar = "sidebar.leading"
    public static let message = "text.bubble"
    public static let profile = "timer"
    public static let status = "gauge.with.dots.needle.33percent"
    public static let text = "doc.plaintext"
    public static let form = "list.bullet.below.rectangle"

    // Actions
    public static let run = "play.fill"
    public static let runAll = "forward.fill"
    public static let stop = "stop.fill"
    public static let explain = "point.3.connected.trianglepath.dotted"
    public static let commit = "checkmark.circle"
    public static let rollback = "arrow.uturn.backward.circle"
    public static let refresh = "arrow.clockwise"
    public static let search = "magnifyingglass"
    public static let filter = "line.3.horizontal.decrease.circle"
    public static let add = "plus"
    public static let remove = "minus"
    public static let close = "xmark"
    public static let export = "square.and.arrow.up"
    public static let importData = "square.and.arrow.down"
    public static let history = "clock.arrow.circlepath"
    public static let snippet = "text.badge.plus"
    public static let format = "wand.and.sparkles"
    public static let copy = "doc.on.doc"
    public static let paste = "doc.on.clipboard"
    public static let edit = "pencil"
    public static let duplicate = "plus.square.on.square"
    public static let rename = "character.cursor.ibeam"
    public static let delete = "trash"
    public static let disconnect = "bolt.slash"
    public static let lock = "lock"
    public static let unlock = "lock.open"
    public static let production = "exclamationmark.triangle.fill"
    public static let readOnly = "lock.fill"
    public static let more = "ellipsis.circle"
    public static let settings = "gearshape"
    public static let command = "command"
    public static let goTo = "arrow.right.circle"
    public static let maintenance = "wrench.and.screwdriver"
    public static let newQuery = "plus.rectangle.on.rectangle"
    public static let openInNewTab = "rectangle.badge.plus"
    public static let firstPage = "chevron.left.to.line"
    public static let previousPage = "chevron.left"
    public static let nextPage = "chevron.right"
    public static let lastPage = "chevron.right.to.line"
    public static let sortAscending = "chevron.up"
    public static let moveUp = "arrow.up"
    public static let moveDown = "arrow.down"
    public static let chevronDown = "chevron.down"
    public static let sortDescending = "chevron.down"
    public static let expand = "chevron.down"
    public static let collapse = "chevron.right"
    public static let key = "key.fill"
    public static let shield = "checkmark.shield"
    public static let info = "info.circle"
    public static let success = "checkmark.circle.fill"
    public static let warning = "exclamationmark.triangle.fill"
    public static let error = "xmark.octagon.fill"
    public static let transaction = "arrow.triangle.2.circlepath"
    public static let save = "square.and.arrow.down"
    public static let open = "folder"
    public static let null = "circle.slash"
    public static let keyword = "textformat.abc"
    public static let welcome = "sparkles"
}

extension ConnectionColor {
    /// The SwiftUI colour for a connection's dot and tab stripe.
    public var swiftUIColor: Color {
        Color(nsColor: DesignTokens.Colors.connection(self))
    }

    public var displayName: String { rawValue.capitalized }
}

extension ConnectionState {
    /// The sidebar's status dot.
    public var indicatorColor: Color {
        switch self {
        case .disconnected: .secondary
        case .connecting: .yellow
        case .connected: .green
        case .degraded: .red
        }
    }

    public var describedForStatusBar: String {
        switch self {
        case .disconnected: "Disconnected"
        case let .connecting(stage): "Connecting (\(stage.rawValue))…"
        case .connected: "Connected"
        case let .degraded(reason): reason
        }
    }
}

extension TableKind {
    public var symbolName: String {
        switch self {
        case .table, .partitionedTable: Icon.table
        case .view: Icon.view
        case .materializedView: Icon.materializedView
        case .foreignTable: Icon.foreignTable
        case .systemTable: Icon.systemTable
        }
    }

    /// How the kind reads in a list.
    public var displayName: String {
        switch self {
        case .table: "Table"
        case .partitionedTable: "Partitioned table"
        case .view: "View"
        case .materializedView: "Materialized view"
        case .foreignTable: "Foreign table"
        case .systemTable: "System table"
        }
    }
}

extension RoutineKind {
    public var symbolName: String {
        switch self {
        case .procedure: Icon.procedure
        case .trigger: Icon.trigger
        default: Icon.function
        }
    }
}
