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

/// Reading the multi-line fields of the Redis forms; the rules live in `DBRedis`.
enum RedisNewKeyParsing {
    static func pairs(_ text: String) -> [RedisPair] { RedisNewKeyText.pairs(text) }
    static func items(_ text: String) -> [Data] { RedisNewKeyText.items(text) }
    static func scored(_ text: String) -> [RedisScoredMember]? { RedisNewKeyText.scored(text) }
}

/// New Key: a name, one of the data types the server has, the type's own settings, a
/// first value and an optional expiry.
struct RedisNewKeySheet: View {
    @Bindable var controller: RedisTabController
    let onDone: () -> Void

    @State private var name = ""
    @State private var kind: RedisNewKeyKind = .string
    @State private var text = ""
    @State private var ttl = ""
    @State private var settings: [RedisNewKeySetting.Name: String] = [:]
    @State private var problem: String?
    @State private var isSaving = false
    @State private var typedName = ""

    private var productionName: String? {
        controller.config?.isProduction == true ? controller.config?.name : nil
    }

    /// Only what this server can create: a type whose commands it lacks is not offered.
    private var kinds: [RedisNewKeyKind] { RedisNewKeyKind.available(on: controller.info) }

    var body: some View {
        SheetFrame(title: "New Key", icon: Icon.redisKey, subtitle: "In db\(controller.database). Creating never overwrites a key.") {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                FieldRow(label: "Name") {
                    TextField("e.g. user:42", text: $name).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                }
                FieldRow(label: "Type") {
                    BarPopUp(items: kinds.map { BarPopUp.Item(id: $0, title: $0.displayName) }, selection: $kind)
                        .frame(width: 200)
                        .accessibilityLabel("type")
                    Text("TYPE \(kind.keyType.scanName)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .help("What the server's TYPE command will answer for this key")
                }
                ForEach(kind.settings) { setting in
                    FieldRow(label: setting.label) {
                        TextField(
                            setting.placeholder,
                            text: Binding(
                                get: { settings[setting.name] ?? "" }, set: { settings[setting.name] = $0 })
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: setting.name == .labels ? 300 : 200)
                    }
                }
                FieldRow(label: "Expires in") {
                    TextField("never", text: $ttl).textFieldStyle(.roundedBorder).frame(width: 120)
                    Text("seconds").font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    Text(kind.prompt).font(.caption).foregroundStyle(.secondary)
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
        .onChange(of: kind) { _, _ in
            // The settings of one type mean nothing to the next.
            settings = [:]
            problem = nil
        }
    }

    private func create() async {
        let initial: RedisInitialValue
        do {
            initial = try kind.initialValue(from: text)
        } catch {
            problem = (error as? RedisNewKeyProblem)?.description ?? String(describing: error)
            return
        }
        if kind == .json, (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) == nil {
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
        if await controller.create(name: name, kind: kind, initial: initial, settings: settings, ttlSeconds: seconds) {
            onDone()
        } else {
            problem = controller.failure
            controller.failure = nil
        }
    }
}
