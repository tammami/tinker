import DBCore
import DBRedis
import SwiftUI

/// Commands typed as in `redis-cli`, answered as `redis-cli` prints them.
struct RedisConsoleView: View {
    @Bindable var controller: RedisTabController
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                        if controller.console.isEmpty {
                            Text(
                                "Type a command and press Return — GET user:1, HGETALL session:42, SCAN 0 MATCH order:*. "
                                    + "↑ and ↓ walk the history; CLEAR empties this pane."
                            )
                            .font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(controller.console) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: DesignTokens.Spacing.xs) {
                                    Text("db\(controller.database)>").foregroundStyle(.tertiary)
                                    Text(entry.command).fontWeight(.semibold)
                                    Spacer()
                                    if entry.milliseconds > 0 {
                                        Text("\(entry.milliseconds) ms").font(.caption2).foregroundStyle(.tertiary)
                                    }
                                }
                                Text(entry.output)
                                    .foregroundStyle(entry.isError ? Color.red : Color.primary)
                                    .textSelection(.enabled)
                            }
                            .font(.system(.body, design: .monospaced))
                            .id(entry.id)
                        }
                    }
                    .padding(DesignTokens.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: controller.console.count) { _, _ in
                    if let last = controller.console.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            HStack(spacing: DesignTokens.Spacing.sm) {
                Text("db\(controller.database)>").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                TextField("Command", text: $controller.consoleInput)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .focused($isInputFocused)
                    .onSubmit { controller.runConsole() }
                    .onKeyPress(.upArrow) {
                        controller.historyStep(-1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        controller.historyStep(1)
                        return .handled
                    }
                if controller.isRunningCommand { ProgressView().controlSize(.small) }
                IconButton(icon: Icon.run, label: "Run (Return)") { controller.runConsole() }
                IconButton(icon: Icon.delete, label: "Clear the console") { controller.clearConsole() }
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .frame(height: DesignTokens.Metrics.barHeight)
        }
        .onAppear { isInputFocused = true }
    }
}

/// The server's own view of itself: INFO by section, the clients, the slow log and the
/// configuration. Read when the pane is opened and on Refresh, never polled.
struct RedisServerView: View {
    @Bindable var controller: RedisTabController

    enum Pane: String, CaseIterable, Identifiable {
        case info = "Info"
        case clients = "Clients"
        case slowlog = "Slow Log"
        case config = "Configuration"
        var id: String { rawValue }
    }

    @State private var pane: Pane = .info
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            PaneBar {
                Picker("Pane", selection: $pane) {
                    ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Image(systemName: Icon.search).foregroundStyle(.secondary)
                TextField("Filter", text: $filter).textFieldStyle(.plain).frame(width: 160)
                IconButton(icon: Icon.refresh, label: "Refresh") { Task { await controller.loadServer() } }
            }
            .controlSize(.small)
            Divider()
            switch pane {
            case .info:
                SimpleTable(
                    columns: [.init(title: "Section", width: 120), .init(title: "Field", width: 260), .init(title: "Value")],
                    rows: (controller.serverInfo?.sections ?? []).flatMap { section in
                        section.fields.map { [section.name, $0.key, $0.value] }
                    }.filter(matches))
            case .clients:
                SimpleTable(
                    columns: [
                        .init(title: "ID", width: 60, isNumeric: true), .init(title: "Address", width: 160),
                        .init(title: "Name", width: 120), .init(title: "DB", width: 40, isNumeric: true),
                        .init(title: "Age", width: 70, isNumeric: true), .init(title: "Idle", width: 60, isNumeric: true),
                        .init(title: "Last command"),
                    ],
                    rows: controller.clients.map {
                        [$0["id"] ?? "", $0["addr"] ?? "", $0["name"] ?? "", $0["db"] ?? "", $0["age"] ?? "", $0["idle"] ?? "", $0["cmd"] ?? ""]
                    }.filter(matches))
            case .slowlog:
                SimpleTable(
                    columns: [.init(title: "When", width: 170), .init(title: "Took", width: 90, isNumeric: true), .init(title: "Command")],
                    rows: controller.slowlog.filter(matches))
            case .config:
                SimpleTable(
                    columns: [.init(title: "Parameter", width: 280), .init(title: "Value")],
                    rows: controller.configuration.map { [$0.0, $0.1] }.filter(matches))
            }
        }
        .task { await controller.loadServer() }
    }

    private func matches(_ row: [String]) -> Bool {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        return needle.isEmpty || row.contains { $0.localizedCaseInsensitiveContains(needle) }
    }
}

/// Reading the new-key form's multi-line fields.
enum RedisNewKeyParsing {
    /// `field=value` per line; a line without `=` is a field with an empty value.
    static func pairs(_ text: String) -> [RedisPair] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return RedisPair(
                field: RedisText.parse(String(parts[0]).trimmingCharacters(in: .whitespaces)),
                value: RedisText.parse(parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""))
        }
    }

    /// One element per line.
    static func items(_ text: String) -> [Data] {
        text.split(whereSeparator: \.isNewline).map { RedisText.parse(String($0)) }.filter { !$0.isEmpty }
    }

    /// `score member` per line. Nil when a score does not parse.
    static func scored(_ text: String) -> [RedisScoredMember]? {
        var result: [RedisScoredMember] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let score = String(parts[0])
            guard Double(score) != nil || ["inf", "+inf", "-inf"].contains(score.lowercased()) else { return nil }
            result.append(RedisScoredMember(member: RedisText.parse(String(parts[1])), score: score))
        }
        return result
    }
}

/// New Key: a name, a type, a first value and an optional expiry.
struct RedisNewKeySheet: View {
    @Bindable var controller: RedisTabController
    let hasJSON: Bool
    let onDone: () -> Void

    @State private var name = ""
    @State private var type: RedisKeyType = .string
    @State private var text = ""
    @State private var ttl = ""
    @State private var problem: String?
    @State private var isSaving = false
    @State private var typedName = ""

    private var productionName: String? {
        controller.config?.isProduction == true ? controller.config?.name : nil
    }

    private var types: [RedisKeyType] { RedisKeyType.allCases.filter { $0 != .json || hasJSON } }

    private var prompt: String {
        switch type {
        case .string: "The value"
        case .json: #"A JSON document, e.g. {"name": "Ada"}"#
        case .hash: "One field=value per line"
        case .list, .set: "One element per line"
        case .zset: "One \"score member\" per line, e.g. 1.5 ada"
        case .stream: "The first entry: one field=value per line"
        case .other: ""
        }
    }

    var body: some View {
        SheetFrame(title: "New Key", icon: Icon.redisKey, subtitle: "In db\(controller.database). Creating never overwrites a key.") {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                FieldRow(label: "Name") {
                    TextField("e.g. user:42", text: $name).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                }
                FieldRow(label: "Type") {
                    Picker("Type", selection: $type) {
                        ForEach(types, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
                FieldRow(label: "Expires in") {
                    TextField("never", text: $ttl).textFieldStyle(.roundedBorder).frame(width: 120)
                    Text("seconds").font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    Text(prompt).font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 140)
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.smallCornerRadius))
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignTokens.Metrics.smallCornerRadius)
                                .strokeBorder(Color.primary.opacity(0.1)))
                }
                if let problem { InlineBanner(kind: .error, message: problem) { self.problem = nil } }
            }
        } footer: {
            if let productionName {
                ProductionGate(connectionName: productionName, requiresTypedName: true, typed: $typedName)
            }
            Spacer()
            Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
            Button(isSaving ? "Creating…" : "Create") { Task { await create() } }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(
                    name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving
                        || !ProductionGate.passes(productionName: productionName, requiresTypedName: true, typed: typedName))
        }
    }

    private func create() async {
        let initial: RedisInitialValue
        switch type {
        case .string, .json:
            initial = .text(text)
        case .hash, .stream:
            initial = .pairs(RedisNewKeyParsing.pairs(text))
        case .list, .set:
            initial = .items(RedisNewKeyParsing.items(text))
        case .zset:
            guard let scored = RedisNewKeyParsing.scored(text) else {
                problem = "Each line is a number, a space, then the member."
                return
            }
            initial = .scored(scored)
        case .other:
            return
        }
        if type == .json, (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) == nil {
            problem = "That is not valid JSON."
            return
        }
        let seconds = Int64(ttl.trimmingCharacters(in: .whitespaces))
        if !ttl.trimmingCharacters(in: .whitespaces).isEmpty, (seconds ?? 0) <= 0 {
            problem = "The expiry is a whole number of seconds, or empty for never."
            return
        }
        isSaving = true
        defer { isSaving = false }
        controller.failure = nil
        if await controller.create(name: name, type: type, initial: initial, ttlSeconds: seconds) {
            onDone()
        } else {
            problem = controller.failure
            controller.failure = nil
        }
    }
}
