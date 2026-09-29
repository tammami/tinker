import DBCore
import DBRedis
import SwiftUI

/// Transfer, Data Synchronization and Structure Synchronization between Redis databases.
///
/// Both ends are Redis — another server, or another logical database of the same one.
/// SQL connections are not offered here, and Redis connections are not offered in the
/// SQL tools: a key–value store has no faithful mapping to tables.
struct RedisToolsSheet: View {
    let request: RedisToolRequest
    let environment: AppEnvironment
    let onDismiss: () -> Void

    @State private var kind: RedisToolKind = .transfer
    @State private var sourceID: UUID?
    @State private var sourceDatabase = 0
    @State private var targetID: UUID?
    @State private var targetDatabase = 1
    @State private var pattern = "*"
    @State private var types: Set<RedisKeyType> = []
    @State private var existing: RedisTransferOptions.ExistingKeys = .replace
    @State private var keepTTL = true
    @State private var deleteExtras = false

    @State private var isRunning = false
    @State private var progress: RedisTransferProgress?
    @State private var compared = 0
    @State private var plan: RedisSyncPlan?
    @State private var structure: [RedisStructureChange]?
    @State private var chosenChanges: Set<String> = []
    @State private var failure: String?
    @State private var finished: String?
    @State private var typedName = ""
    @State private var work: Task<Void, Never>?
    /// Bumped per run: progress reported by an earlier or finished run is ignored.
    @State private var runNumber = 0
    /// What deleting the target's extras asks to be typed.
    @State private var typedDatabase = ""
    /// Databases each Redis connection has, once asked; 16 until then.
    @State private var databaseCounts: [UUID: Int] = [:]

    private var connections: [ConnectionConfig] { environment.redisConnections }
    private var target: ConnectionConfig? { connections.first { $0.id == targetID } }
    private var sameEnds: Bool { sourceID == targetID && sourceDatabase == targetDatabase }
    private var productionName: String? { target?.isProduction == true ? target?.name : nil }

    var body: some View {
        SheetFrame(
            title: "Redis \(kind.rawValue)", icon: icon,
            subtitle: subtitle,
            width: DesignTokens.Metrics.wideSheetWidth
        ) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                Picker("Tool", selection: $kind) {
                    ForEach(RedisToolKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(isRunning)
                .onChange(of: kind) { _, _ in reset() }

                if connections.isEmpty {
                    Label("There is no Redis connection yet. Add one with New Connection › Redis.", systemImage: Icon.info)
                        .foregroundStyle(.secondary)
                } else {
                    endpoints
                    options
                    results
                }
                if let failure { InlineBanner(kind: .error, message: failure) { self.failure = nil } }
                if let finished { InlineBanner(kind: .success, message: finished) { self.finished = nil } }
            }
        } footer: {
            if let productionName {
                ProductionGate(connectionName: productionName, requiresTypedName: true, typed: $typedName)
            }
            Spacer()
            if isRunning {
                Button("Stop") { work?.cancel() }
            }
            // Closing stops a run: it never goes on writing behind a sheet that is gone.
            Button("Close") {
                work?.cancel()
                onDismiss()
            }
            .keyboardShortcut(.cancelAction)
            primaryButton
        }
        .onAppear(perform: start)
    }

    private var icon: String {
        switch kind {
        case .transfer: Icon.transfer
        case .dataSync: Icon.sync
        case .structureSync: Icon.structureSync
        }
    }

    private var subtitle: String {
        switch kind {
        case .transfer: "Copies keys, with their TTL, from one Redis database to another."
        case .dataSync: "Makes the target's keys match the source's: adds, replaces and optionally deletes."
        case .structureSync: "Search indexes and stream consumer groups: what is not a value."
        }
    }

    // MARK: - Form

    private var endpoints: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.lg) {
            endpoint("Source", id: $sourceID, database: $sourceDatabase)
            Image(systemName: Icon.nextPage).foregroundStyle(.secondary).padding(.top, DesignTokens.Spacing.lg)
            endpoint("Target", id: $targetID, database: $targetDatabase)
        }
        .disabled(isRunning)
    }

    private func endpoint(_ title: String, id: Binding<UUID?>, database: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: DesignTokens.Spacing.sm) {
                Picker(title, selection: id) {
                    ForEach(connections) { config in
                        Text(config.name + (config.isProduction ? "  (production)" : "")).tag(Optional(config.id))
                    }
                }
                .labelsHidden()
                .frame(width: 220)
                Picker("Database", selection: database) {
                    ForEach(0 ..< max(databaseCounts[id.wrappedValue ?? UUID()] ?? 16, database.wrappedValue + 1), id: \.self) {
                        Text("db\($0)").tag($0)
                    }
                }
                .labelsHidden()
                .frame(width: 80)
            }
        }
        .onChange(of: id.wrappedValue) { _, _ in reset() }
        .onChange(of: database.wrappedValue) { _, _ in reset() }
    }

    @ViewBuilder
    private var options: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            FieldRow(label: "Keys") {
                TextField("*", text: $pattern).textFieldStyle(.roundedBorder).frame(width: 220)
                    .help("A MATCH pattern: * any text, ? one character, [abc] one of")
                if kind != .structureSync {
                    Menu(types.isEmpty ? "All types" : types.map(\.displayName).sorted().joined(separator: ", ")) {
                        Button("All types") { types = [] }
                        Divider()
                        // Every documented type: the module types travel as DUMP payloads.
                        ForEach(RedisKeyType.documented, id: \.self) { type in
                            Toggle(
                                type.displayName,
                                isOn: Binding(
                                    get: { types.contains(type) },
                                    set: { if $0 { types.insert(type) } else { types.remove(type) } }))
                        }
                    }
                    .fixedSize()
                }
            }
            switch kind {
            case .transfer:
                FieldRow(label: "Existing keys") {
                    Picker("Existing", selection: $existing) {
                        Text("Replace them").tag(RedisTransferOptions.ExistingKeys.replace)
                        Text("Leave them").tag(RedisTransferOptions.ExistingKeys.skip)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Toggle("Keep each key's remaining time to live", isOn: $keepTTL)
            case .dataSync:
                Toggle("Keep each key's remaining time to live", isOn: $keepTTL)
                Toggle("Delete keys that are only in the target", isOn: $deleteExtras)
            case .structureSync:
                Toggle("Drop indexes and consumer groups that are only in the target", isOn: $deleteExtras)
            }
            if sameEnds {
                Label("The source and the target are the same database.", systemImage: Icon.warning)
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .disabled(isRunning)
    }

    @ViewBuilder
    private var results: some View {
        if isRunning {
            HStack(spacing: DesignTokens.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text(runningText).font(.callout).monospacedDigit()
            }
        }
        if let plan, kind == .dataSync, deleteExtras, !plan.removed.isEmpty {
            FieldRow(label: "Type db\(targetDatabase)") {
                TextField("db\(targetDatabase)", text: $typedDatabase).textFieldStyle(.roundedBorder).frame(width: 120)
                Text("to delete \(plan.removed.count) key\(plan.removed.count == 1 ? "" : "s") only in the target")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        if let plan, kind == .dataSync {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                HStack(spacing: DesignTokens.Spacing.md) {
                    Badge(text: "\(plan.added.count) TO ADD", color: .green)
                    Badge(text: "\(plan.changed.count) TO REPLACE", color: .orange)
                    Badge(text: "\(plan.removed.count) ONLY IN TARGET", color: deleteExtras ? .red : .secondary)
                    Badge(text: "\(plan.unchanged) SAME")
                }
                SimpleTable(
                    columns: [.init(title: "Change", width: 110), .init(title: "Key")],
                    rows: Array(
                        (plan.added.map { ["add", $0.display] } + plan.changed.map { ["replace", $0.display] }
                            + plan.removed.map { [deleteExtras ? "delete" : "keep (target only)", $0.display] }).prefix(1_000)))
                .frame(height: 180)
                if plan.added.count + plan.changed.count + plan.removed.count > 1_000 {
                    Text("The first 1,000 are listed; all are applied.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if let structure, kind == .structureSync {
            if structure.isEmpty {
                Label("The structures match.", systemImage: Icon.success).foregroundStyle(.green)
            } else {
                List(structure) { change in
                    Toggle(isOn: Binding(
                        get: { chosenChanges.contains(change.id) },
                        set: { if $0 { chosenChanges.insert(change.id) } else { chosenChanges.remove(change.id) } }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(change.summary)
                            Text(change.preview).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(height: 200)
            }
        }
        if let progress, kind != .structureSync, !isRunning {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                if progress.failed > 0 {
                    Text("\(progress.failed) key\(progress.failed == 1 ? "" : "s") could not be written:")
                        .font(.caption.weight(.semibold)).foregroundStyle(.red)
                    SimpleTable(
                        columns: [.init(title: "Key", width: 220), .init(title: "Server said")],
                        rows: progress.failures.map { [$0.key.display, $0.message] })
                    .frame(height: 120)
                }
            }
        }
    }

    private var runningText: String {
        if let progress {
            return "\(progress.copied) copied · \(progress.skipped) left · \(progress.failed) failed · \(progress.scanned) scanned"
        }
        return compared > 0 ? "\(compared) keys compared…" : "Working…"
    }

    @ViewBuilder
    private var primaryButton: some View {
        let gate = ProductionGate.passes(productionName: productionName, requiresTypedName: true, typed: typedName)
        switch kind {
        case .transfer:
            Button("Transfer") { run(transfer) }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(!ready || !gate)
        case .dataSync:
            if let plan, !plan.isEmpty {
                let deletes = deleteExtras && !plan.removed.isEmpty
                Button("Apply") { run { await apply(plan) } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!ready || !gate || (deletes && typedDatabase != "db\(targetDatabase)"))
            } else {
                Button("Compare") { run(compareData) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!ready)
            }
        case .structureSync:
            if let structure, !structure.isEmpty {
                Button("Apply \(chosenChanges.count)") { run { await applyStructure(structure) } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!ready || !gate || chosenChanges.isEmpty)
            } else {
                Button("Compare") { run(compareStructure) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!ready)
            }
        }
    }

    private var ready: Bool { !isRunning && sourceID != nil && targetID != nil && !sameEnds }

    // MARK: - Running

    private func start() {
        Task {
            for config in connections {
                if let info = try? await environment.redisSession(for: config.id)?.connect() {
                    databaseCounts[config.id] = info.databaseCount
                }
            }
        }
        kind = request.kind
        let first = connections.first?.id
        sourceID = request.connectionID.flatMap { id in connections.contains { $0.id == id } ? id : nil } ?? first
        sourceDatabase = request.database
        // Another connection when there is one, else the next database of the same server.
        targetID = connections.first { $0.id != sourceID }?.id ?? sourceID
        targetDatabase = targetID == sourceID ? (request.database == 0 ? 1 : 0) : request.database
    }

    private func reset() {
        typedDatabase = ""
        plan = nil
        structure = nil
        progress = nil
        chosenChanges = []
        finished = nil
        compared = 0
    }

    private func resolveEnds() -> (RedisEndpoint, RedisEndpoint)? {
        guard let sourceID, let targetID, let source = environment.redisSession(for: sourceID),
            let target = environment.redisSession(for: targetID)
        else { return nil }
        return (RedisEndpoint(session: source, database: sourceDatabase), RedisEndpoint(session: target, database: targetDatabase))
    }

    private var transferOptions: RedisTransferOptions {
        RedisTransferOptions(
            pattern: pattern.trimmingCharacters(in: .whitespaces).isEmpty ? "*" : pattern, types: types,
            existing: existing, keepTTL: keepTTL)
    }

    private func run(_ body: @escaping @MainActor () async -> Void) {
        failure = nil
        finished = nil
        isRunning = true
        runNumber += 1
        let current = runNumber
        work = Task { @MainActor in
            await body()
            if current == runNumber { isRunning = false }
        }
    }

    /// Progress from the run in flight, dropped once that run has reported its result.
    private func report(_ state: RedisTransferProgress, for current: Int) {
        guard current == runNumber, isRunning else { return }
        progress = state
    }

    /// Refuses before anything is written when the target is locked.
    private func targetIsWritable(_ target: RedisEndpoint) async -> Bool {
        if await target.session.isReadOnly {
            failure = "The target connection is read-only. Unlock it with ⌘⇧L first."
            return false
        }
        return true
    }

    private func transfer() async {
        guard let (source, target) = resolveEnds(), await targetIsWritable(target) else { return }
        progress = RedisTransferProgress()
        do {
            let current = runNumber
            let result = try await RedisTransfer.copy(from: source, to: target, options: transferOptions) { state in
                Task { @MainActor in report(state, for: current) }
            }
            progress = result
            finished = "\(result.copied) key\(result.copied == 1 ? "" : "s") copied, \(result.skipped) left as they were"
                + (result.failed > 0 ? ", \(result.failed) failed." : ".")
        } catch is CancellationError {
            failure = "Stopped. Keys copied so far stay in the target."
        } catch {
            failure = message(error)
        }
    }

    private func compareData() async {
        guard let (source, target) = resolveEnds() else { return }
        do {
            plan = try await RedisDataSync.compare(source: source, target: target, options: transferOptions) { count in
                Task { @MainActor in compared = count }
            }
            if plan?.isEmpty == true { finished = "The target already matches the source." }
        } catch is CancellationError {
            failure = "Stopped."
        } catch {
            failure = message(error)
        }
    }

    private func apply(_ plan: RedisSyncPlan) async {
        guard let (source, target) = resolveEnds(), await targetIsWritable(target) else { return }
        progress = RedisTransferProgress()
        do {
            let result = try await RedisDataSync.apply(
                plan, source: source, target: target, deleteExtras: deleteExtras, keepTTL: keepTTL
            ) { [current = runNumber] state in
                Task { @MainActor in report(state, for: current) }
            }
            progress = result
            self.plan = nil
            finished = "\(result.copied) key\(result.copied == 1 ? "" : "s") written, \(result.deleted) deleted"
                + (result.failed > 0 ? ", \(result.failed) failed." : ".")
        } catch is CancellationError {
            failure = "Stopped part-way; compare again to see what is left."
        } catch {
            failure = message(error)
        }
    }

    private func compareStructure() async {
        guard let (source, target) = resolveEnds() else { return }
        do {
            let changes = try await RedisStructureSync.compare(
                source: source, target: target, pattern: pattern.isEmpty ? "*" : pattern, dropExtras: deleteExtras)
            structure = changes
            // Creating is chosen by default; dropping has to be asked for one by one.
            chosenChanges = Set(changes.filter { $0.action != .drop }.map(\.id))
        } catch {
            failure = message(error)
        }
    }

    private func applyStructure(_ changes: [RedisStructureChange]) async {
        guard let (_, target) = resolveEnds(), await targetIsWritable(target) else { return }
        let chosen = changes.filter { chosenChanges.contains($0.id) }
        do {
            try await RedisStructureSync.apply(chosen, target: target)
            finished = "\(chosen.count) change\(chosen.count == 1 ? "" : "s") applied."
            structure = nil
            chosenChanges = []
        } catch {
            failure = message(error)
        }
    }

    private func message(_ error: any Error) -> String {
        (error as? DBError)?.errorDescription ?? String(describing: error)
    }
}
