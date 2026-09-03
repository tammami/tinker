import DBCore
import SwiftUI

/// The workspace's tab strip. Custom rather than `NSTabView` so tabs can carry a
/// connection colour stripe and be reordered by dragging (SPEC §10.1).
public struct TabBarView: View {
    @Bindable var workspace: WorkspaceModel
    let onNewTab: () -> Void

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(workspace.tabs.enumerated()), id: \.element.id) { index, tab in
                    TabChip(
                        tab: tab,
                        isSelected: workspace.selectedTabID == tab.id,
                        color: color(for: tab),
                        onSelect: { workspace.selectedTabID = tab.id },
                        onClose: { workspace.closeTab(tab.id) }
                    )
                    .draggable(tab.id.uuidString) {
                        Text(tab.title).padding(4)
                    }
                    .dropDestination(for: String.self) { items, _ in
                        guard let moved = items.first,
                              let from = workspace.tabs.firstIndex(where: { $0.id.uuidString == moved })
                        else { return false }
                        workspace.moveTab(from: from, to: index)
                        return true
                    }
                }
                Button(action: onNewTab) {
                    Image(systemName: "plus")
                        .frame(width: 28, height: DesignTokens.Metrics.tabHeight)
                }
                .buttonStyle(.borderless)
                .help("New query tab (⌘T)")
                Spacer(minLength: 0)
            }
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

struct TabChip: View {
    let tab: WorkspaceTab
    let isSelected: Bool
    let color: Color?
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            if let color {
                Rectangle().fill(color).frame(width: 3, height: 14).clipShape(Capsule())
            }
            Image(systemName: tab.isQueryTab ? "text.alignleft" : "tablecells")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(tab.title)
                .lineLimit(1)
                .font(.system(size: 12))
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.borderless)
            .opacity(isHovering || isSelected ? 1 : 0)
            .help("Close tab (⌘W)")
        }
        .padding(.horizontal, 10)
        .frame(height: DesignTokens.Metrics.tabHeight)
        .background(isSelected ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.25) : .clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isSelected ? Color.accentColor : .clear)
                .frame(height: 2)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }
}
