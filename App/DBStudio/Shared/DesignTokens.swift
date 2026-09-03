import AppKit
import DBCore
import SwiftUI

/// Every colour, metric and font the UI uses.
///
/// Colours map to system semantic colours so dark mode, increased contrast and
/// accessibility settings follow automatically. The only hard-coded colours are the seven
/// connection colours, which are identities rather than theme values (SPEC §10.1).
public enum DesignTokens {
    public enum Metrics {
        /// Fixed grid row height. Fixed, not automatic, because uniform heights are what
        /// let the table view scroll a million rows (SPEC §12).
        public static let gridRowHeight: CGFloat = 22
        public static let gridHeaderHeight: CGFloat = 24
        public static let minimumColumnWidth: CGFloat = 40
        public static let defaultColumnWidth: CGFloat = 140
        public static let maximumColumnWidth: CGFloat = 1_200
        /// Text longer than this is truncated in a cell; the full value is in the inspector.
        public static let inCellTextLimit = 512
        public static let sidebarMinWidth: CGFloat = 220
        public static let inspectorWidth: CGFloat = 280
        public static let tabHeight: CGFloat = 28
    }

    public enum Colors {
        public static let editedCell = NSColor.systemYellow.withAlphaComponent(0.28)
        public static let insertedRow = NSColor.systemGreen.withAlphaComponent(0.22)
        public static let deletedRow = NSColor.systemRed.withAlphaComponent(0.20)
        public static let nullText = NSColor.tertiaryLabelColor
        public static let binaryText = NSColor.secondaryLabelColor
        public static let productionBadge = NSColor.systemRed

        /// The hairline between grid columns.
        ///
        /// Faint on purpose: it only has to separate two columns, and at full strength a
        /// wide table reads as a cage of lines rather than as rows of values.
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

        /// The editor font, from settings, falling back to SF Mono 13 (SPEC §13.1).
        public static func editor(name: String = "SF Mono", size: CGFloat = 13) -> NSFont {
            NSFont(name: name, size: size)
                ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }
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
        case .table, .partitionedTable: "tablecells"
        case .view: "eye"
        case .materializedView: "square.stack.3d.down.right"
        case .foreignTable: "link"
        case .systemTable: "gearshape"
        }
    }
}
