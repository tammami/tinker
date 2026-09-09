import DBCore
import DBSQL
import DBStore
import SwiftUI

/// The snippet library (⌘⇧K): saved SQL with placeholders, inserted at the caret.
public struct SnippetsView: View {
    let environment: AppEnvironment
    let dialect: SQLDialect
    let onInsert: (String) -> Void
    let onDismiss: () -> Void

    @State private var snippets: [Snippet] = []
    @State private var search = ""
    @State private var selectedID: Int64?
    @State private var draft: Snippet?
    @FocusState private var isSearchFocused: Bool

    public var body: some View {
        SheetFrame(
            title: "Snippets",
            icon: Icon.snippet,
            subtitle: "Reusable SQL. Placeholders like ${1:table} are selected after insertion.",
            width: DesignTokens.Metrics.wideSheetWidth,
            contentInset: 0
        ) {
            HSplitView {
                list.frame(minWidth: 240, idealWidth: 260)
                editor.frame(minWidth: 380)
            }
            .frame(height: 420)
        } footer: {
            Button {
                let fresh = Snippet(
                    name: "New snippet", body: "SELECT * FROM ${1:table} WHERE ${2:condition};", dialect: nil)
                draft = fresh
                selectedID = nil
            } label: {
                Label("New", systemImage: Icon.add)
            }
            Spacer()
            Button("Close", action: onDismiss).keyboardShortcut(.cancelAction)
            Button {
                if let draft { onInsert(SnippetTemplate.expand(draft.body).text) }
            } label: {
                Label("Insert", systemImage: Icon.query)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(draft == nil)
        }
        .task { await reload() }
        .onAppear { isSearchFocused = true }
    }

    private var visible: [Snippet] {
        guard !search.isEmpty else { return snippets }
        return snippets.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.body.localizedCaseInsensitiveContains(search)
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: Icon.search).foregroundStyle(.secondary)
                TextField("Search", text: $search).textFieldStyle(.plain).focused($isSearchFocused)
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .frame(height: DesignTokens.Metrics.barHeight)
            Divider()
            if visible.isEmpty {
                EmptyStateView(
                    icon: Icon.snippet, title: snippets.isEmpty ? "No snippets yet" : "No match",
                    message: snippets.isEmpty
                        ? "Save SQL you type often, with placeholders for the parts that change." : nil)
            } else {
                List(selection: $selectedID) {
                    ForEach(visible) { snippet in
                        HStack(spacing: DesignTokens.Spacing.sm) {
                            Image(systemName: Icon.snippet)
                                .foregroundStyle(.secondary)
                                .frame(width: DesignTokens.Metrics.iconWidth)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(snippet.name).lineLimit(1)
                                Text(snippet.body.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if let dialect = snippet.dialect {
                                Badge(text: dialect == "mysql" ? "MySQL" : "PG")
                            }
                        }
                        .tag(snippet.id)
                        .contextMenu {
                            Button(role: .destructive) {
                                Task {
                                    await environment.deleteSnippet(id: snippet.id)
                                    await reload()
                                    if draft?.id == snippet.id { draft = nil }
                                }
                            } label: {
                                Label("Delete", systemImage: Icon.delete)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .onChange(of: selectedID) { _, id in
                    draft = snippets.first { $0.id == id }
                }
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let current = draft {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    TextField("Name", text: Binding(get: { current.name }, set: { draft?.name = $0 }))
                        .textFieldStyle(.roundedBorder)
                    Picker(
                        "Engine",
                        selection: Binding(
                            get: { current.dialect ?? "" },
                            set: { draft?.dialect = $0.isEmpty ? nil : $0 }
                        )
                    ) {
                        Text("Any engine").tag("")
                        Text("PostgreSQL").tag(SQLDialect.postgresql.rawValue)
                        Text("MySQL").tag(SQLDialect.mysql.rawValue)
                        Text("SQLite").tag(SQLDialect.sqlite.rawValue)
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
                TextEditor(text: Binding(get: { current.body }, set: { draft?.body = $0 }))
                    .font(.system(.body, design: .monospaced))
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.smallCornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Metrics.smallCornerRadius)
                            .strokeBorder(Color.primary.opacity(0.1))
                    )
                HStack {
                    Text("Preview: ")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(
                        SnippetTemplate.expand(current.body).text.split(whereSeparator: \.isNewline).first.map(
                            String.init) ?? ""
                    )
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    Spacer()
                    Button {
                        Task {
                            let id = await environment.saveSnippet(current)
                            await reload()
                            selectedID = id
                            draft = snippets.first { $0.id == id }
                        }
                    } label: {
                        Label("Save", systemImage: Icon.save)
                    }
                    .controlSize(.small)
                    .disabled(current.name.trimmingCharacters(in: .whitespaces).isEmpty || current.body.isEmpty)
                }
            }
            .padding(DesignTokens.Spacing.lg)
        } else {
            EmptyStateView(
                icon: Icon.snippet, title: "Choose a snippet",
                message: "Pick one on the left to read, edit or insert it.")
        }
    }

    private func reload() async {
        snippets = await environment.snippets(dialect: dialect)
    }
}
