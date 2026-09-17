import DBCore
import DBSQL
import SwiftUI

/// What the sheet was opened for: a new event, or one that already exists.
public struct EventEditorRequest: Identifiable, Sendable, Hashable {
    public enum Mode: Sendable, Hashable {
        case create
        case edit(name: String)
    }

    public let id = UUID()
    public let mode: Mode
    public let connectionID: UUID
    public let schema: SchemaRef

    public init(mode: Mode, connectionID: UUID, schema: SchemaRef) {
        self.mode = mode
        self.connectionID = connectionID
        self.schema = schema
    }

    public var existingName: String? {
        if case let .edit(name) = mode { return name }
        return nil
    }
}

/// Builds one `CREATE EVENT` or `ALTER EVENT`, and reports whether the server would ever
/// run it — MySQL stores an event whose scheduler is off without a word of complaint.
@MainActor
@Observable
final class EventEditorController {
    let request: EventEditorRequest
    private let environment: AppEnvironment

    var name = ""
    var repeats = true
    var intervalValue = "1"
    var intervalField: EventIntervalField = .day
    var executeAt = ""
    var starts = ""
    var ends = ""
    var preserveOnCompletion = true
    var isEnabled = true
    var comment = ""
    var body = ""

    private(set) var schedulerState: SchedulerState = .unsupported
    /// The event as the catalogue reported it, so an edit can tell what actually changed.
    private(set) var loaded: EventInfo?
    /// The zone the server reads a schedule in — not this Mac's zone.
    private(set) var serverTimeZone = ""
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var isEnablingScheduler = false
    private(set) var failure: String?
    private(set) var schedulerFailure: String?
    /// Set when the statement was accepted but reading the variable back was not. The
    /// scheduler is running; only the confirmation is missing.
    private(set) var schedulerUnconfirmed: String?
    private var version = ServerVersion(major: 0, minor: 0, patch: 0, flavor: .mysql, rawString: "")

    init(request: EventEditorRequest, environment: AppEnvironment) {
        self.request = request
        self.environment = environment
    }

    private var session: ConnectionSession? {
        environment.session(for: request.connectionID, schema: request.schema)
    }

    var connectionName: String {
        environment.connections.first { $0.id == request.connectionID }?.name ?? ""
    }

    var productionName: String? {
        let config = environment.connections.first { $0.id == request.connectionID }
        return config?.isProduction == true ? config?.name : nil
    }

    var isEditing: Bool { request.existingName != nil }

    var title: String { isEditing ? "Edit Event" : "New Event" }

    /// `SET PERSIST` survives a restart; MySQL 8.0+ only.
    var schedulerChangePersists: Bool { EventOperations.schedulerChangePersists(version) }

    /// A `DISABLED` scheduler was fixed at server start; no statement can move it.
    var canOfferToEnableScheduler: Bool { schedulerState == .off }

    var schedulerWarning: (message: String, hint: String)? {
        Self.schedulerWarning(for: schedulerState, persists: schedulerChangePersists)
    }

    /// Pure, for testing.
    static func schedulerWarning(
        for state: SchedulerState, persists: Bool
    ) -> (message: String, hint: String)? {
        switch state {
        case .on, .unsupported:
            return nil
        case .off:
            return (
                "The server's event scheduler is off, so this event will be saved but never run.",
                persists
                    ? "Turning it on needs the SUPER or SYSTEM_VARIABLES_ADMIN privilege. It stays on after a restart."
                    : "Turning it on needs the SUPER or SYSTEM_VARIABLES_ADMIN privilege, and this server forgets it when it restarts — set event_scheduler=ON in my.cnf to make it stick."
            )
        case .disabled:
            return (
                "The server was started with the event scheduler disabled, so this event will be saved but never run.",
                "No statement can change that. The server has to be restarted without --event-scheduler=DISABLED, or with event_scheduler=ON in my.cnf."
            )
        }
    }

    /// A time already past is the third reason an event looks like it did nothing.
    var pastScheduleHint: String? {
        Self.pastScheduleHint(repeats ? starts : executeAt, repeats: repeats, now: Date())
    }

    /// Pure, for testing against a fixed clock.
    static func pastScheduleHint(_ text: String, repeats: Bool, now: Date) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let moment = timestampFormatter.date(from: trimmed), moment < now
        else { return nil }
        return repeats
            ? "That start time has already passed. MySQL will run the event at the next interval after it."
            : "That time has already passed. MySQL accepts the event, runs nothing, and then disables it — or deletes it when ON COMPLETION is NOT PRESERVE."
    }

    var eventRequest: EventRequest {
        EventRequest(
            database: request.schema.database,
            name: name,
            schedule: repeats
                ? .every(value: intervalValue, field: intervalField)
                : .at(executeAt),
            // The sheet hides the window when the schedule runs once, so it does not send
            // one either; the generator refuses the contradiction rather than dropping it.
            starts: repeats && !starts.isEmpty ? starts : nil,
            ends: repeats && !ends.isEmpty ? ends : nil,
            preserveOnCompletion: preserveOnCompletion,
            isEnabled: isEnabled,
            comment: comment.isEmpty ? nil : comment,
            body: body)
    }

    /// The statement as it will be sent, or the reason it cannot be built yet.
    /// True when the schedule fields still say what the catalogue said.
    var scheduleIsUnchanged: Bool {
        guard let loaded else { return false }
        return repeats == (loaded.scheduleKind == .recurring)
            && intervalValue == (loaded.intervalValue ?? "1")
            && intervalField.rawValue == (loaded.intervalField?.uppercased() ?? intervalField.rawValue)
            && executeAt == (loaded.executeAt ?? "")
            && starts == (loaded.starts ?? "")
            && ends == (loaded.ends ?? "")
    }

    /// The event's own time zone is what its timestamps mean; the session's is what an
    /// `ALTER` that re-states them would be read in.
    var scheduleTimeZone: String { loaded?.timeZone.isEmpty == false ? loaded!.timeZone : serverTimeZone }

    /// True when saving would re-state a schedule written in another zone, which would move
    /// the event without the person asking for it.
    var wouldRestateForeignSchedule: Bool {
        guard let loaded, !loaded.timeZone.isEmpty, !serverTimeZone.isEmpty else { return false }
        return !scheduleIsUnchanged && loaded.timeZone.uppercased() != serverTimeZone.uppercased()
    }

    var preview: Result<String, any Error> {
        do {
            if let existing = request.existingName {
                return .success(
                    try EventOperations.alter(
                        eventRequest, renamedFrom: existing,
                        includingSchedule: !scheduleIsUnchanged, dialect: .mysql))
            }
            return .success(try EventOperations.create(eventRequest, dialect: .mysql))
        } catch {
            return .failure(error)
        }
    }

    var statement: String? {
        if case let .success(sql) = preview { return sql }
        return nil
    }

    var problem: String? {
        if case let .failure(error) = preview {
            return (error as? EventOperationsError)?.description ?? String(describing: error)
        }
        return nil
    }

    func load() async {
        guard let session, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            version = try await session.connect()
            try await session.withLease { connection in
                guard let server = connection.introspector.server else { return }
                schedulerState = (try? await server.schedulerState()) ?? .unsupported
                // `--ui-demo events-off` shows the warning without reconfiguring anyone's
                // server. Read only while a demo runs: the key outlives its launch, and a
                // stale one would put a false "scheduler is off" on a real server.
                if CommandLine.arguments.contains("--ui-demo"),
                    let forced = UserDefaults.standard.string(forKey: "uiDemo.schedulerState"),
                    let state = SchedulerState(rawValue: forced)
                {
                    schedulerState = state
                }
                let zone = try? await connection.executeCollecting(
                    "SELECT @@session.time_zone, @@global.system_time_zone")
                if let row = zone?.rows.first, row.count >= 2 {
                    let sessionZone = row[0].text ?? ""
                    serverTimeZone =
                        sessionZone.uppercased() == "SYSTEM" ? (row[1].text ?? sessionZone) : sessionZone
                }
            }
            if let existing = request.existingName {
                let events = try await session.introspection(.events(request.schema)) {
                    guard let server = $0.server else { return [EventInfo]() }
                    return try await server.events(in: request.schema)
                }
                if let event = events.first(where: { $0.name == existing }) {
                    loaded = event
                    apply(event)
                }
            }
        } catch {
            failure = (error as? DBError)?.errorDescription ?? String(describing: error)
        }
    }

    /// Filled from the catalog, not `SHOW CREATE EVENT`: nothing has to be parsed.
    private func apply(_ event: EventInfo) {
        name = event.name
        repeats = event.scheduleKind == .recurring
        intervalValue = event.intervalValue ?? "1"
        intervalField =
            event.intervalField.flatMap { EventIntervalField(rawValue: $0.uppercased()) } ?? .day
        executeAt = event.executeAt ?? ""
        starts = event.starts ?? ""
        ends = event.ends ?? ""
        preserveOnCompletion = !event.deletesItself
        isEnabled = event.isEnabled
        comment = event.comment ?? ""
        body = event.definition
    }

    /// Sends the statement whole on a leased connection, never through the splitter: a
    /// body may hold semicolons and MySQL's splitter does not track `BEGIN … END`.
    func save() async -> Bool {
        guard let session, let statement, !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        failure = nil
        if await session.isReadOnly {
            failure = "This connection is read-only. Unlock it with ⌘⇧L first."
            return false
        }
        do {
            try await session.withLease { connection in
                _ = try await connection.executeCollecting(statement)
            }
            await session.invalidateIntrospection(.events(request.schema))
            if let existing = request.existingName {
                await session.invalidateIntrospection(
                    .eventDefinition(request.schema, name: existing))
            }
            return true
        } catch {
            failure = (error as? DBError)?.errorDescription ?? String(describing: error)
            return false
        }
    }

    /// Starts the scheduler, showing the server's refusal verbatim when the account may
    /// not — that message names the privilege to ask a DBA for.
    func enableScheduler() async {
        guard let session, !isEnablingScheduler else { return }
        isEnablingScheduler = true
        defer { isEnablingScheduler = false }
        schedulerFailure = nil
        schedulerUnconfirmed = nil
        do {
            let statement = try EventOperations.setScheduler(
                on: true, dialect: .mysql, persists: schedulerChangePersists)
            try await session.withLease { connection in
                _ = try await connection.executeCollecting(statement)
                guard let server = connection.introspector.server else { return }
                do {
                    schedulerState = try await server.schedulerState()
                } catch {
                    // The server accepted the statement, so the scheduler is on; only the
                    // read back failed. Leaving the state at .off would keep the warning up
                    // and send the reader to a DBA over a change that already went through.
                    schedulerState = .on
                    schedulerUnconfirmed =
                        (error as? DBError)?.errorDescription ?? String(describing: error)
                }
            }
        } catch {
            schedulerFailure = (error as? DBError)?.errorDescription ?? String(describing: error)
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

/// The event editor: a schedule, a body, and whether the server will act on either.
struct EventEditorSheet: View {
    @Bindable var controller: EventEditorController
    let fontName: String
    let fontSize: Double
    let onDismiss: () -> Void

    @State private var typedName = ""
    /// Dismissed for this sheet only; it comes back next time.
    @State private var schedulerWarningDismissed = false

    var body: some View {
        SheetFrame(
            title: controller.title,
            icon: Icon.event,
            subtitle: "\(controller.connectionName) · \(controller.request.schema.database)",
            width: DesignTokens.Metrics.wideSheetWidth
        ) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                schedulerBanner
                form
                bodyEditor
                previewOrProblem
                if let failure = controller.failure {
                    InlineBanner(kind: .error, message: failure) { controller.clearFailure() }
                }
            }
        } footer: {
            if let production = controller.productionName {
                ProductionGate(connectionName: production, requiresTypedName: true, typed: $typedName)
            }
            Spacer()
            Button("Cancel", action: onDismiss).keyboardShortcut(.cancelAction)
            Button(controller.isSaving ? "Saving…" : (controller.isEditing ? "Save" : "Create")) {
                Task { if await controller.save() { onDismiss() } }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(
                controller.statement == nil || controller.isSaving
                    || !ProductionGate.passes(
                        productionName: controller.productionName, requiresTypedName: true,
                        typed: typedName)
            )
        }
        .task { await controller.load() }
    }

    /// Said before anything is saved, not after nothing runs.
    @ViewBuilder
    private var schedulerBanner: some View {
        if let warning = controller.schedulerWarning, !schedulerWarningDismissed {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                InlineBanner(
                    kind: .warning, message: warning.message, hint: warning.hint,
                    onDismiss: { schedulerWarningDismissed = true })
                if controller.canOfferToEnableScheduler {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        Spacer()
                        Button(
                            controller.isEnablingScheduler ? "Enabling…" : "Enable Scheduler"
                        ) {
                            Task { await controller.enableScheduler() }
                        }
                        // A whole-server change, so it waits on the typed name too.
                        .disabled(
                            controller.isEnablingScheduler
                                || !ProductionGate.passes(
                                    productionName: controller.productionName,
                                    requiresTypedName: true, typed: typedName)
                        )
                        .help(
                            controller.productionName == nil
                                ? "" : "Type the connection's name in the footer to enable this")
                    }
                }
                if let refusal = controller.schedulerFailure {
                    InlineBanner(
                        kind: .error, message: refusal,
                        hint: "Ask whoever administers the server to set event_scheduler=ON.",
                        onDismiss: { controller.clearSchedulerFailure() })
                }
                if let unconfirmed = controller.schedulerUnconfirmed {
                    InlineBanner(
                        kind: .warning,
                        message: "The scheduler was started, but reading its state back failed.",
                        detail: unconfirmed,
                        hint: "Reopen this sheet to check it.",
                        onDismiss: { controller.clearSchedulerUnconfirmed() })
                }
            }
        }
    }

    @ViewBuilder
    private var form: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            FieldRow(label: "Name") {
                TextField("nightly_clear", text: $controller.name)
                    .textFieldStyle(.roundedBorder)
            }
            FieldRow(label: "Schedule") {
                Picker("", selection: $controller.repeats) {
                    Text("Repeats").tag(true)
                    Text("Once").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            if controller.repeats {
                FieldRow(label: "Every") {
                    TextField("1", text: $controller.intervalValue)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Picker("", selection: $controller.intervalField) {
                        ForEach(EventIntervalField.allCases, id: \.self) { field in
                            Text(field.title).tag(field)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                }
                FieldRow(label: "Starts") {
                    TextField("now", text: $controller.starts).textFieldStyle(.roundedBorder)
                }
                FieldRow(label: "Ends") {
                    TextField("never", text: $controller.ends).textFieldStyle(.roundedBorder)
                }
            } else {
                FieldRow(label: "At") {
                    TextField("2026-01-01 00:00:00", text: $controller.executeAt)
                        .textFieldStyle(.roundedBorder)
                }
            }
            // The server's clock, rarely this Mac's.
            if !controller.scheduleTimeZone.isEmpty {
                FieldRow(label: "") {
                    Text("Times are read in the zone \(controller.scheduleTimeZone)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            if controller.wouldRestateForeignSchedule {
                FieldRow(label: "") {
                    Label(
                        "This event's times were written in \(controller.scheduleTimeZone); saving a"
                            + " changed schedule rewrites them in this session's \(controller.serverTimeZone).",
                        systemImage: Icon.warning
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            if let hint = controller.pastScheduleHint {
                FieldRow(label: "") {
                    Label(hint, systemImage: Icon.warning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            FieldRow(label: "Comment") {
                TextField("what this event is for", text: $controller.comment)
                    .textFieldStyle(.roundedBorder)
            }
            FieldRow(label: "") {
                Toggle("Enabled", isOn: $controller.isEnabled)
                Toggle("Keep after the last run", isOn: $controller.preserveOnCompletion)
                    .help(
                        "MySQL deletes an event when this is off and its schedule has finished")
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var bodyEditor: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            SectionHeading(text: "Statement to run")
            SQLEditorView(
                text: $controller.body,
                dialect: .mysql,
                fontName: fontName,
                fontSize: fontSize
            )
            .frame(minHeight: 120, idealHeight: 150)
            .clipShape(
                RoundedRectangle(cornerRadius: DesignTokens.Metrics.smallCornerRadius))
        }
    }

    @ViewBuilder
    private var previewOrProblem: some View {
        if let problem = controller.problem {
            Label(problem, systemImage: Icon.info)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let statement = controller.statement {
            StatementPreview(sql: statement, maxHeight: 120)
        }
    }
}

extension EventEditorController {
    func clearFailure() { failure = nil }
    func clearSchedulerFailure() { schedulerFailure = nil }
    func clearSchedulerUnconfirmed() { schedulerUnconfirmed = nil }
}
