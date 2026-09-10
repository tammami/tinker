import AppKit
import SwiftUI

/// Which help page the window shows. The menu sets it before opening the window, so
/// Keyboard Shortcuts lands on that page rather than the first one.
@MainActor
@Observable
final class HelpNavigation {
    static let shared = HelpNavigation()
    var selectedTopicID: String? = HelpContent.topics.first?.id
}

/// The built-in help: topics on the left, the page on the right, a search field on top.
///
/// It is a window of its own (`HelpView.windowID`) rather than an Apple Help book, so it
/// needs no Help Indexer, ships inside the binary, and reads the same in dark mode.
struct HelpView: View {
    static let windowID = "help"

    @State private var navigation = HelpNavigation.shared
    @State private var query = ""

    private var topics: [HelpTopic] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return HelpContent.topics }
        return HelpContent.topics.filter { $0.searchText.contains(needle) }
    }

    private var selected: HelpTopic? {
        HelpContent.topic(id: navigation.selectedTopicID ?? "") ?? HelpContent.topics.first
    }

    var body: some View {
        NavigationSplitView {
            List(topics, selection: $navigation.selectedTopicID) { topic in
                Label(topic.title, systemImage: topic.icon)
                    .tag(topic.id)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
            .overlay {
                if topics.isEmpty {
                    EmptyStateView(icon: Icon.search, title: "No matching page", message: "Try another word.")
                }
            }
        } detail: {
            if let selected {
                HelpPageView(topic: selected, highlight: query)
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search help")
        .navigationTitle("\(Product.name) Help")
        .frame(minWidth: 720, minHeight: 480)
        // Help is opened on purpose, not restored: a launch should not bring it back.
        .background(NonRestorableWindow().frame(width: 0, height: 0))
        .onChange(of: topics) { _, visible in
            // A search that hides the current page moves to the first one still shown.
            if let id = navigation.selectedTopicID, !visible.contains(where: { $0.id == id }) {
                navigation.selectedTopicID = visible.first?.id
            }
        }
    }
}

/// One help page: the title, its summary, then each section as prose or a shortcut table.
struct HelpPageView: View {
    let topic: HelpTopic
    let highlight: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    Label(topic.title, systemImage: topic.icon)
                        .font(.title2.weight(.semibold))
                    Text(topic.summary).foregroundStyle(.secondary)
                }
                ForEach(Array(topic.sections.enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                        if let heading = section.heading {
                            Text(heading).font(.headline)
                        }
                        ForEach(section.paragraphs, id: \.self) { paragraph in
                            Text(paragraph)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !section.shortcuts.isEmpty {
                            shortcutTable(section.shortcuts)
                        }
                    }
                }
                HStack(spacing: DesignTokens.Spacing.md) {
                    if let url = HelpLinks.releaseNotes {
                        Link(destination: url) { Label("Release Notes", systemImage: Icon.releaseNotes) }
                    }
                    if let url = HelpLinks.issues {
                        Link(destination: url) { Label("Report an Issue", systemImage: Icon.bug) }
                    }
                }
                .font(.callout)
                .padding(.top, DesignTokens.Spacing.md)
            }
            .padding(DesignTokens.Spacing.xl)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(topic.id)
    }

    /// Key caps on the left, what they do on the right, on alternating rows.
    private func shortcutTable(_ shortcuts: [HelpShortcut]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(shortcuts.enumerated()), id: \.offset) { index, shortcut in
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.md) {
                    KeyCap(keys: shortcut.keys)
                        .frame(width: 96, alignment: .leading)
                    Text(shortcut.action)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .padding(.vertical, DesignTokens.Spacing.xs + 1)
                .background(index.isMultiple(of: 2) ? Color.primary.opacity(0.04) : Color.clear)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.smallCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Metrics.smallCornerRadius)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }
}

/// Marks the window this view lands in as not restorable, so macOS does not reopen it
/// on the next launch the way it does the workspace windows.
private struct NonRestorableWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> MarkingView { MarkingView() }
    func updateNSView(_ view: MarkingView, context: Context) {}

    final class MarkingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.isRestorable = false
        }
    }
}
