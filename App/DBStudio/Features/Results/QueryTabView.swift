import DBCore
import DBGrid
import DBSQL
import SwiftUI

/// A query tab: editor above, one result tab per statement below (SPEC §13).
public struct QueryTabView: View {
    @Bindable var controller: QueryTabController
    @Bindable var workspace: WorkspaceModel
    let tab: WorkspaceTab
    let fontName: String
    let fontSize: Double

    @State private var editorSelection: Range<Int>?

    public var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                SQLEditorView(
                    text: $controller.sql,
                    dialect: controller.dialect,
                    fontName: fontName,
                    fontSize: fontSize,
                    errorPosition: controller.errorBanner?.position,
                    delegate: controller
                )
                Divider()
                editorToolbar
            }
            .frame(minHeight: 120, idealHeight: 240)

            VStack(spacing: 0) {
                if let banner = controller.errorBanner {
                    ErrorBanner(
                        message: banner.sqlState.map { "[\($0)] \(banner.message)" } ?? banner.message,
                        detail: banner.detail,
                        hint: banner.hint,
                        onCopy: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(banner.copyText, forType: .string)
                        },
                        onDismiss: { controller.errorBanner = nil }
                    )
                    Divider()
                }

                if controller.results.count > 1 {
                    resultTabBar
                    Divider()
                }

                resultContent
            }
            .frame(minHeight: 120)
        }
        .task(id: tab.id) {
            controller.sql = tab.sql
            await controller.loadSessionChoices()
            await controller.loadCompletionSources()
        }
        .onChange(of: controller.sql) { _, new in tab.sql = new }
        .onDisappear {
            let controller = controller
            Task { await controller.releaseHeldConnection() }
        }
    }

    var editorToolbar: some View {
        HStack(spacing: 10) {
            Button {
                controller.run(all: false)
            } label: {
                Label("Run", systemImage: "play.fill")
            }
            .disabled(controller.isRunning)
            .help("Run the statement under the cursor (⌘↩)")

            Button {
                controller.run(all: true)
            } label: {
                Label("Run All", systemImage: "forward.fill")
            }
            .disabled(controller.isRunning)
            .help("Run every statement (⌘⇧↩)")

            if controller.isRunning {
                Button {
                    controller.cancel()
                } label: {
                    Label("Cancel", systemImage: "stop.fill")
                }
                .help("Cancel on the server (⌘.)")
                ProgressView().controlSize(.small)
                Text(QueryTabController.format(controller.elapsed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Divider().frame(height: 14)

            // The tab's session (SPEC §13.1a): statements resolve unqualified names here.
            Picker("", selection: Binding(
                get: { controller.connectionID },
                set: { id in Task { await controller.selectConnection(id) } }
            )) {
                ForEach(controller.availableConnections) { config in
                    Text(config.name).tag(config.id)
                }
            }
            .labelsHidden()
            .frame(width: 160)
            .help("The connection this tab runs on")

            Picker("", selection: Binding(
                get: { controller.sessionDatabase ?? "" },
                set: { name in Task { await controller.selectDatabase(name) } }
            )) {
                if controller.sessionDatabase == nil {
                    Text("Choose…").tag("")
                }
                ForEach(controller.availableDatabases, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .labelsHidden()
            .frame(width: 170)
            .help(
                controller.dialect == .mysql
                    ? "The database unqualified names resolve against (USE)"
                    : "The schema unqualified names resolve against (search_path)"
            )

            Divider().frame(height: 14)

            Toggle("Auto-commit", isOn: Binding(
                get: { controller.autoCommit },
                set: { value in Task { await controller.setAutoCommit(value) } }
            ))
            .toggleStyle(.checkbox)
            .controlSize(.small)

            if controller.isInTransaction {
                Text("Transaction open")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Button("Commit") { Task { await controller.commitTransaction() } }
                    .controlSize(.small)
                Button("Rollback") { Task { await controller.rollbackTransaction() } }
                    .controlSize(.small)
            }

            Spacer()

            Text(controller.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(.bar)
    }

    var resultTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(controller.results) { result in
                    Button {
                        controller.selectedResultID = result.id
                    } label: {
                        HStack(spacing: 4) {
                            if result.error != nil {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(.red)
                                    .font(.caption)
                            }
                            Text(result.label).lineLimit(1).font(.system(size: 11))
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(
                            controller.selectedResultID == result.id
                                ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.25)
                                : .clear
                        )
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 24)
        .background(.bar)
    }

    @State private var resultPane: ResultPane = .result

    /// Which pane of a result is showing (SPEC §13.2a).
    enum ResultPane: String, CaseIterable, Identifiable {
        case message = "Message"
        case result = "Result"
        case profile = "Profile"
        case status = "Status"
        var id: String { rawValue }
    }

    @ViewBuilder
    var resultContent: some View {
        if let result = controller.selectedResult {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Picker("", selection: $resultPane) {
                        ForEach(ResultPane.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 340)
                    Spacer()
                }
                .padding(.vertical, 5)
                Divider()

                switch resultPane {
                case .message: messagePane(result)
                case .result: rowsPane(result)
                case .profile: tablePane(
                    columns: result.profileColumns, rows: result.profile, note: result.profileNote
                )
                .task(id: result.id) { await controller.loadProfile(for: result) }
                case .status: tablePane(
                    columns: result.statusColumns, rows: result.status, note: result.statusNote
                )
                .task(id: result.id) { await controller.loadStatus(for: result) }
                }
            }
        } else {
            ContentUnavailableView("Run a statement to see results", systemImage: "play")
        }
    }

    /// The statement and what the server said about it.
    private func messagePane(_ result: QueryResultTab) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("sql").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(result.statement)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("message").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(result.error?.message ?? result.message ?? "OK")
                        .font(.callout)
                        .foregroundStyle(result.error == nil ? Color.primary : Color.red)
                        .textSelection(.enabled)
                }
                if let completion = result.completion {
                    Text((completion.serverTag ?? "") + " • " + Self.milliseconds(completion.durationTotal))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }

    /// A pane that is just a table of strings: Profile and Status both are.
    @ViewBuilder
    private func tablePane(
        columns: [String], rows: [[String]]?, note: String?
    ) -> some View {
        if let note {
            ContentUnavailableView {
                Text("Not available")
            } description: {
                Text(note)
            }
        } else if let rows, !rows.isEmpty {
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(Array(columns.enumerated()), id: \.offset) { _, name in
                            Text(name)
                                .font(.caption.weight(.semibold))
                                .frame(width: 200, alignment: .leading)
                                .padding(.horizontal, 6)
                        }
                    }
                    .padding(.vertical, 5)
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        HStack(spacing: 0) {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                                Text(value)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(width: 200, alignment: .leading)
                                    .padding(.horizontal, 6)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 2)
                        .background(
                            index.isMultiple(of: 2)
                                ? Color.clear
                                : Color(nsColor: .alternatingContentBackgroundColors[1])
                        )
                    }
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    static func milliseconds(_ duration: Duration) -> String {
        let ms = Double(duration.components.attoseconds) / 1e15
            + Double(duration.components.seconds) * 1000
        return String(format: "%.3f s", ms / 1000)
    }

    @ViewBuilder
    private func rowsPane(_ result: QueryResultTab) -> some View {
        VStack(spacing: 0) {
                if let grid = result.grid {
                    DataGridView(
                        model: grid,
                        selection: $controller.selection,
                        revision: controller.revision,
                        delegate: controller
                    )
                    if grid.hasReachedMemoryCap {
                        memoryCapBanner
                    }
                } else {
                    VStack {
                        Text(result.message ?? "No rows")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                HStack(spacing: 10) {
                    // What produced the rows on screen, so it is never in doubt.
                    Text(result.statement)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if let completion = result.completion {
                        Text(Self.milliseconds(completion.durationTotal))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if let grid = result.grid {
                        Text("\(grid.displayRowCount) record\(grid.displayRowCount == 1 ? "" : "s")")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(.bar)
        }
    }

    /// Shown once a result reaches the in-memory row cap (SPEC §12.1).
    var memoryCapBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
            Text("Showing the first 200,000 rows. Export to a file to get the rest.")
                .font(.caption)
            Spacer()
            Button("Export…") { workspace.isExportPresented = true }
                .controlSize(.small)
        }
        .padding(8)
        .background(Color.orange.opacity(0.12))
    }
}
