import DBCore
import DBRedis
import SwiftUI

/// A Redis tab: Keys (browse and edit), Console (commands, as in `redis-cli`), Server
/// (INFO, clients, slow log, configuration).
struct RedisTabView: View {
    @Bindable var controller: RedisTabController
    @State private var isCreatingKey = false
    @State private var isDeletingPattern = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let failure = controller.failure {
                InlineBanner(kind: .error, message: failure) { controller.failure = nil }
                    .padding(DesignTokens.Spacing.sm)
            }
            switch controller.mode {
            case .keys: keysPane
            case .console: RedisConsoleView(controller: controller)
            case .server: RedisServerView(controller: controller)
            }
        }
        .task { await controller.start() }
        .sheet(isPresented: $isCreatingKey) {
            RedisNewKeySheet(controller: controller, hasJSON: controller.info?.hasJSON ?? false) {
                isCreatingKey = false
            }
        }
        .sheet(isPresented: $isDeletingPattern) {
            RedisDeletePatternSheet(initial: controller.pattern) { pattern in
                isDeletingPattern = false
                if let pattern { controller.deleteMatching(pattern) }
            }
        }
    }

    private var header: some View {
        PaneBar {
            HStack(spacing: DesignTokens.Spacing.xs + 2) {
                EngineMark(redis: true, size: DesignTokens.Metrics.iconWidth)
                Text(controller.config?.name ?? "Redis").font(.system(size: DesignTokens.Typography.body, weight: .semibold))
                if let info = controller.info {
                    Text("\(info.product) \(info.version)").font(.caption).foregroundStyle(.tertiary)
                }
            }
            BarDivider()
            Menu {
                ForEach(0 ..< (controller.info?.databaseCount ?? 16), id: \.self) { index in
                    Button("db\(index)") { Task { await controller.switchDatabase(index) } }
                }
            } label: {
                Label("db\(controller.database)", systemImage: Icon.database)
            }
            .fixedSize()
            .help("The logical database this tab works in")
            Picker("Mode", selection: $controller.mode) {
                ForEach(RedisTabController.Mode.allCases) { mode in
                    Label(mode.rawValue, systemImage: icon(mode)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            if controller.config?.isProduction == true {
                Badge(text: "PRODUCTION", color: .red)
            }
            if let notice = controller.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(4))
                        if controller.notice == notice { controller.notice = nil }
                    }
            }
        }
        .controlSize(.small)
    }

    private func icon(_ mode: RedisTabController.Mode) -> String {
        switch mode {
        case .keys: Icon.redisKey
        case .console: Icon.console
        case .server: Icon.activity
        }
    }

    // MARK: - Keys

    private var keysPane: some View {
        HSplitView {
            VStack(spacing: 0) {
                keyFilterBar
                Divider()
                RedisKeyList(controller: controller)
                Divider()
                keyStatusBar
            }
            .frame(minWidth: 300, idealWidth: 440)
            Group {
                if let selected = controller.selectedKey {
                    RedisKeyDetailView(controller: controller, info: selected)
                        .id(selected.key)
                } else {
                    EmptyStateView(
                        icon: Icon.redisKey,
                        title: controller.keys.isEmpty && controller.isComplete ? "No keys here" : "Choose a key",
                        message: controller.keys.isEmpty && controller.isComplete
                            ? "db\(controller.database) has no keys matching \(controller.pattern). Add one to start."
                            : "Pick a key on the left to see and edit its value."
                    ) {
                        Button("New Key…") { isCreatingKey = true }
                    }
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var keyFilterBar: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: Icon.search).foregroundStyle(.secondary)
            TextField("Pattern, e.g. user:*", text: $controller.pattern)
                .textFieldStyle(.plain)
                .onSubmit { Task { await controller.rescan() } }
                .help("A MATCH pattern: * any text, ? one character, [abc] one of. Press Return to search.")
            Menu {
                Button("All types") {
                    controller.typeFilter = nil
                    Task { await controller.rescan() }
                }
                Divider()
                ForEach(RedisKeyType.allCases, id: \.self) { type in
                    Button(type.displayName) {
                        controller.typeFilter = type
                        Task { await controller.rescan() }
                    }
                }
            } label: {
                Label(controller.typeFilter?.displayName ?? "All types", systemImage: Icon.filter)
            }
            .fixedSize()
            IconButton(icon: Icon.refresh, label: "Search again") { Task { await controller.rescan() } }
        }
        .controlSize(.small)
        .padding(.horizontal, DesignTokens.Spacing.md)
        .frame(height: DesignTokens.Metrics.barHeight)
    }

    private var keyStatusBar: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text(
                controller.isScanning
                    ? "Scanning…"
                    : "\(controller.keys.count) key\(controller.keys.count == 1 ? "" : "s")\(controller.isComplete ? "" : " so far")"
            )
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if !controller.isComplete, !controller.isScanning, controller.hasScanned {
                Button("Load More") { Task { await controller.loadMore() } }
            }
            Spacer()
            IconButton(icon: Icon.add, label: "New key") { isCreatingKey = true }
            IconButton(icon: Icon.delete, label: "Delete the selected keys (⌫)", isDestructive: true) { controller.deleteSelectedKeys() }
                .disabled(controller.selection.isEmpty)
            Menu {
                Button("Delete Keys Matching a Pattern…") { isDeletingPattern = true }
                Button("Empty db\(controller.database)…") { controller.flushDatabase() }
            } label: {
                Image(systemName: Icon.more)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .controlSize(.small)
        .padding(.horizontal, DesignTokens.Spacing.md)
        .frame(height: DesignTokens.Metrics.statusHeight)
    }
}

/// The key list: a native table of name, type, TTL and length, many rows selectable.
struct RedisKeyList: View {
    @Bindable var controller: RedisTabController
    @State private var renaming: RedisKeyInfo?
    @State private var newName = ""

    var body: some View {
        Table(controller.keys, selection: $controller.selection) {
            TableColumn("Key") { info in
                Text(info.key.display).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    .help(info.key.display)
            }
            .width(min: 140, ideal: 280)
            TableColumn("Type") { info in
                RedisTypeBadge(type: info.type)
            }
            .width(min: 50, ideal: 70, max: 100)
            TableColumn("TTL") { info in
                Text(RedisFormat.ttl(info.ttlMilliseconds)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 40, ideal: 60, max: 90)
            TableColumn("Size") { info in
                Text(info.length.map { String($0) } ?? "").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 40, ideal: 60, max: 90)
        }
        .contextMenu(forSelectionType: Data.self) { ids in
            if let id = ids.first, let info = controller.keys.first(where: { $0.id == id }) {
                Button("Copy Name") { RedisFormat.copy(info.key.display) }
                Button("Rename…") {
                    newName = info.key.display
                    renaming = info
                }
                .disabled(ids.count != 1)
                Divider()
                Button(ids.count == 1 ? "Delete Key…" : "Delete \(ids.count) Keys…") {
                    controller.selection = ids
                    controller.deleteSelectedKeys()
                }
            }
        } primaryAction: { ids in
            if let id = ids.first, let info = controller.keys.first(where: { $0.id == id }) {
                Task { await controller.open(info.key) }
            }
        }
        .onChange(of: controller.selection) { _, selection in
            guard selection.count == 1, let id = selection.first,
                let info = controller.keys.first(where: { $0.id == id }), info.key != controller.selectedKey?.key
            else { return }
            Task { await controller.open(info.key) }
        }
        .onDeleteCommand { controller.deleteSelectedKeys() }
        .alert("Rename Key", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("New name", text: $newName)
            Button("Rename") {
                if let info = renaming { controller.rename(info.key, to: newName) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }
}

struct RedisTypeBadge: View {
    let type: RedisKeyType

    var body: some View {
        Badge(text: label, color: color)
    }

    private var label: String {
        switch type {
        case .string: "STRING"
        case .hash: "HASH"
        case .list: "LIST"
        case .set: "SET"
        case .zset: "ZSET"
        case .stream: "STREAM"
        case .json: "JSON"
        case let .other(name): name.uppercased()
        }
    }

    private var color: Color {
        switch type {
        case .string: .blue
        case .hash: .purple
        case .list: .green
        case .set: .orange
        case .zset: .pink
        case .stream: .teal
        case .json: .indigo
        case .other: .secondary
        }
    }
}

/// Small formatting helpers shared by the Redis views.
enum RedisFormat {
    static func ttl(_ milliseconds: Int64?) -> String {
        guard let milliseconds else { return "∞" }
        let seconds = milliseconds / 1_000
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m \(seconds % 60)s" }
        if seconds < 86_400 { return "\(seconds / 3_600)h \(seconds % 3_600 / 60)m" }
        return "\(seconds / 86_400)d \(seconds % 86_400 / 3_600)h"
    }

    static func bytes(_ count: Int64?) -> String {
        guard let count else { return "" }
        return ByteCountFormatter.string(fromByteCount: count, countStyle: .memory)
    }

    static func text(_ data: Data) -> String { RedisText.display(data) }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Delete every key matching a pattern: the pattern is typed, shown, and typed again.
struct RedisDeletePatternSheet: View {
    let initial: String
    let onDone: (String?) -> Void
    @State private var pattern = ""

    var body: some View {
        SheetFrame(
            title: "Delete Keys Matching a Pattern", icon: Icon.delete,
            subtitle: "Every key SCAN finds for the pattern is unlinked. This cannot be undone."
        ) {
            FieldRow(label: "Pattern") {
                TextField("e.g. session:*", text: $pattern).textFieldStyle(.roundedBorder)
            }
        } footer: {
            Spacer()
            Button("Cancel") { onDone(nil) }.keyboardShortcut(.cancelAction)
            Button("Continue…") { onDone(pattern) }
                .keyboardShortcut(.defaultAction)
                .disabled(RedisTabController.matchesEverything(pattern))
                .help("Deleting everything is Empty Database, which asks for the database's name")
        }
        .onAppear { pattern = initial == "*" ? "" : initial }
    }
}
