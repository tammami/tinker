import DBCore
import SwiftUI

/// The workspace's tab strip. Custom rather than `NSTabView` so tabs can carry a
/// connection colour stripe, an icon for what they hold, and be reordered by dragging.
public struct TabBarView: View {
    @Bindable var workspace: WorkspaceModel
    /// Whether a tab holds edits or an open transaction, answered by whoever owns them.
    let hasUnsavedWork: (WorkspaceTab) -> Bool
    /// Closing goes through the owner of the tab's controllers, so a closed grid is freed.
    let onClose: (UUID) -> Void
    let onCloseOthers: (UUID) -> Void
    let onNewTab: () -> Void

    public var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(workspace.tabs.enumerated()), id: \.element.id) { index, tab in
                        TabChip(
                            tab: tab,
                            isSelected: workspace.selectedTabID == tab.id,
                            color: color(for: tab),
                            hasUnsavedWork: hasUnsavedWork(tab),
                            onSelect: { workspace.selectedTabID = tab.id },
                            onClose: { onClose(tab.id) },
                            onCloseOthers: { onCloseOthers(tab.id) }
                        )
                        .draggable(tab.id.uuidString) {
                            Label(tab.title, systemImage: tab.icon).padding(DesignTokens.Spacing.xs)
                        }
                        .dropDestination(for: String.self) { items, _ in
                            guard let moved = items.first,
                                let from = workspace.tabs.firstIndex(where: { $0.id.uuidString == moved })
                            else { return false }
                            workspace.moveTab(from: from, to: index)
                            return true
                        }
                    }
                }
            }
            IconButton(icon: Icon.add, label: "New query tab (⌘T)", action: onNewTab)
                .padding(.horizontal, DesignTokens.Spacing.xs)
            Spacer(minLength: 0)
        }
        .frame(height: DesignTokens.Metrics.tabHeight)
        .background(.bar)
    }

    func color(for tab: WorkspaceTab) -> Color? {
        workspace.environment.connections
            .first { $0.id == tab.connectionID }?
            .color?.swiftUIColor
    }
}

/// One tab: a colour stripe for its connection, an icon for its kind, its title, and a
/// close button that appears on hover so the strip stays quiet.
struct TabChip: View {
    let tab: WorkspaceTab
    let isSelected: Bool
    let color: Color?
    let hasUnsavedWork: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs + 2) {
            Image(systemName: tab.icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: 14)
            Text(tab.title)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180)
            if hasUnsavedWork {
                Circle().fill(Color.orange).frame(width: 6, height: 6)
                    .help("Uncommitted changes")
            }
            Button(action: onClose) {
                Image(systemName: Icon.close)
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .background(isHovering ? Color.primary.opacity(0.08) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .buttonStyle(.borderless)
            .opacity(isHovering || isSelected ? 1 : 0)
            .help("Close tab (⌘W)")
        }
        .padding(.leading, DesignTokens.Spacing.md)
        .padding(.trailing, DesignTokens.Spacing.sm)
        .frame(height: DesignTokens.Metrics.tabHeight)
        .background(
            isSelected
                ? Color(nsColor: .controlBackgroundColor)
                : (isHovering ? Color.primary.opacity(0.04) : .clear)
        )
        .overlay(alignment: .top) {
            // The connection's colour sits on the top edge, where the eye lands first.
            Rectangle()
                .fill(isSelected ? (color ?? Color.accentColor) : (color ?? .clear))
                .frame(height: 2)
                .opacity(isSelected ? 1 : 0.6)
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Close Tab", action: onClose)
            Button("Close Other Tabs", action: onCloseOthers)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
