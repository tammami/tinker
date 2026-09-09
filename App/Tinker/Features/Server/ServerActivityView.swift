import DBCore
import DBSQL
import Observation
import SwiftUI

/// Reads the server's sessions, users and variables for the Server tab.
///
/// Every read leases a connection and returns it; nothing polls unless the user turns
/// auto-refresh on, and then only while the tab is in front.
@MainActor
@Observable
public final class ServerActivityController {
    public let connectionID: UUID
    public let dialect: SQLDialect

    public private(set) var sessions: [ServerSessionInfo] = []
    public private(set) var users: [ServerUserInfo] = []
    public private(set) var variables: [ServerVariableInfo] = []
    public private(set) var isLoading = false
    public private(set) var errorText: String?
    public private(set) var refreshedAt: Date?
    public var search = ""
    public var selectedSessionID: String?
    public var selectedUserID: String?
    /// The grants of the selected user, read when it is selected.
    public private(set) var grantLines: [String] = []
    /// Which pane to open on, and the database the user editor should default to.
    public var initialPane: String?
    public var focusDatabase: String?
    /// Set by a demo or a command: the view opens the New User sheet once.
    public var wantsNewUserSheet = false
    public var autoRefresh = false {
        didSet { autoRefresh ? startPolling() : stopPolling() }
    }

    private let environment: AppEnvironment
    private var pollTask: Task<Void, Never>?

    public init(connectionID: UUID, dialect: SQLDialect, environment: AppEnvironment) {
        self.connectionID = connectionID
        self.dialect = dialect
        self.environment = environment
    }

    private var session: ConnectionSession? { environment.session(for: connectionID) }

    /// The connection's name when it is marked production, else nil.
    public var productionName: String? {
        let config = environment.connections.first { $0.id == connectionID }
        return config?.isProduction == true ? config?.name : nil
    }

    /// Borrows a connection, reads through its server introspector, returns it.
    private func read<T: Sendable>(_ body: @Sendable (any ServerIntrospector) async throws -> T) async throws -> T {
        guard let session else { throw DBError.notConnected }
        _ = try await session.connect()
        let (lease, connection) = try await session.lease()
        defer { Task { await session.release(lease) } }
        guard let server = connection.introspector.server else {
            throw DBError.protocolError("This driver does not expose server activity")
        }
        return try await body(server)
    }

    public func loadSessions() async {
        isLoading = true
        defer { isLoading = false }
        do {
            sessions = try await read { try await $0.activity() }
            refreshedAt = Date()
            errorText = nil
        } catch {
            errorText = (error as? DBError)?.errorDescription ?? String(describing: error)
        }
    }

    public func loadUsers() async {
        guard users.isEmpty else { return }
        do {
            users = try await read { try await $0.users() }
            errorText = nil
        } catch {
            errorText = (error as? DBError)?.errorDescription ?? String(describing: error)
        }
    }

    public func loadVariables() async {
        guard variables.isEmpty else { return }
        do {
            variables = try await read { try await $0.variables() }
            errorText = nil
        } catch {
            errorText = (error as? DBError)?.errorDescription ?? String(describing: error)
        }
    }

    public func loadGrants(for user: ServerUserInfo) async {
        do {
            grantLines = try await read { try await $0.grants(for: user) }
        } catch {
            grantLines = [(error as? DBError)?.errorDescription ?? String(describing: error)]
        }
    }

    /// Runs user statements one by one on a leased connection and re-reads the users.
    /// Returns the server's message when one fails; the ones before it stay applied.
    public func runUserStatements(_ statements: [String]) async -> String? {
        guard let session else { return "No session for this connection" }
        do {
            if await session.isReadOnly { return "This connection is read-only. Unlock it with ⌘⇧L first." }
            _ = try await session.connect()
            let (lease, connection) = try await session.lease()
            defer { Task { await session.release(lease) } }
            for statement in statements {
                _ = try await connection.executeCollecting(statement)
            }
            users = []
            await loadUsers()
            if let id = selectedUserID, let user = users.first(where: { $0.id == id }) {
                await loadGrants(for: user)
            }
            return nil
        } catch {
            users = []
            await loadUsers()
            return (error as? DBError)?.errorDescription ?? String(describing: error)
        }
    }

    /// The databases the grant picker offers.
    public func databaseNames() async -> [String] {
        guard let session else { return [] }
        switch dialect {
        case .mysql:
            let system: Set<String> = ["information_schema", "performance_schema", "mysql", "sys"]
            return ((try? await session.introspection(.databases) { try await $0.databases() }) ?? [])
                .map(\.name).filter { !system.contains($0) }
        case .postgresql, .sqlite:
            return ((try? await session.introspection(.databases) { try await $0.databases() }) ?? []).map(\.name)
        }
    }

    public func terminate(_ id: String) async {
        do {
            // Ending someone's session is a write in every sense; the lock applies.
            if let session, await session.isReadOnly {
                throw DBError.protocolError("This connection is read-only. Unlock it with ⌘⇧L to end sessions.")
            }
            try await read { try await $0.terminateSession(id: id) }
            await loadSessions()
        } catch {
            errorText = (error as? DBError)?.errorDescription ?? String(describing: error)
        }
    }

    public func clearError() { errorText = nil }
    public func report(_ message: String) { errorText = message }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self else { return }
                await loadSessions()
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    public var visibleSessions: [ServerSessionInfo] {
        guard !search.isEmpty else { return sessions }
        let needle = search.lowercased()
        return sessions.filter {
            [$0.user, $0.database, $0.clientAddress, $0.application, $0.state, $0.query]
                .compactMap { $0?.lowercased() }
                .contains { $0.contains(needle) }
        }
    }

    public var visibleUsers: [ServerUserInfo] {
        guard !search.isEmpty else { return users }
        return users.filter { $0.id.localizedCaseInsensitiveContains(search) }
    }

    public var visibleVariables: [ServerVariableInfo] {
        guard !search.isEmpty else { return variables }
        return variables.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.value.localizedCaseInsensitiveContains(search)
                || ($0.category?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }
}

/// The Server tab: who is connected and what they are running, the accounts, and the
/// server's settings.
public struct ServerActivityView: View {
    @Bindable var controller: ServerActivityController

    enum Pane: String, CaseIterable, Identifiable {
        case sessions = "Sessions"
        case users = "Users"
        case variables = "Variables"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .sessions: Icon.activity
            case .users: Icon.user
            case .variables: Icon.variable
            }
        }
    }

    @State private var pane: Pane = .sessions
    @State private var terminating: ServerSessionInfo?
    @State private var userEditor: UserEditorRequest?
    @State private var droppingUser: ServerUserInfo?
    @FocusState private var isSearchFocused: Bool

    public var body: some View {
        VStack(spacing: 0) {
            PaneBar {
                HStack(spacing: DesignTokens.Spacing.xs + 2) {
                    Image(systemName: Icon.connection).foregroundStyle(Color.accentColor)
                    Text("Server").font(.system(size: 13, weight: .semibold))
                }
                BarDivider()
                Picker("Pane", selection: $pane) {
                    // A SQLite file has no accounts, so there is no Users pane to show.
                    ForEach(Pane.allCases.filter { $0 != .users || controller.dialect.hasUserAccounts }) { pane in
                        Label(pane.rawValue, systemImage: pane.icon).tag(pane)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Image(systemName: Icon.search).foregroundStyle(.secondary)
                    TextField("Filter", text: $controller.search)
                        .textFieldStyle(.plain)
                        .focused($isSearchFocused)
                        .focusesOnSearchCommand($isSearchFocused)
                }
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .frame(width: 200, height: 24)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Metrics.cornerRadius)
                        .strokeBorder(Color.primary.opacity(0.1))
                )
                if pane == .sessions {
                    Toggle(isOn: $controller.autoRefresh) {
                        Label("Auto", systemImage: Icon.transaction)
                    }
                    .toggleStyle(.button)
                    .buttonStyle(.borderless)
                    .help("Refresh every three seconds while this tab is in front")
                }
                if pane == .users {
                    BarDivider()
                    Button {
                        userEditor = UserEditorRequest(mode: .create, database: controller.focusDatabase)
                    } label: {
                        Label("New User", systemImage: "person.badge.plus")
                    }
                    .help("Create a user and grant it privileges on a database")
                    IconButton(icon: Icon.edit, label: "Edit user: password, attributes, grants") {
                        if let user = selectedUser {
                            userEditor = UserEditorRequest(mode: .edit(user), database: controller.focusDatabase)
                        }
                    }
                    .disabled(selectedUser == nil)
                    IconButton(icon: Icon.delete, label: "Drop user", isDestructive: true) {
                        if let user = selectedUser { droppingUser = user }
                    }
                    .disabled(selectedUser == nil)
                }
                IconButton(icon: Icon.refresh, label: "Refresh") { Task { await reload() } }
            }
            .controlSize(.small)
            Divider()

            if let error = controller.errorText {
                InlineBanner(kind: .error, message: error) { controller.clearError() }
                Divider()
            }

            switch pane {
            case .sessions: sessionsPane
            case .users: usersPane
            case .variables: variablesPane
            }

            Divider()
            StatusBarView {
                switch pane {
                case .sessions:
                    Text(
                        "\(controller.visibleSessions.count) session\(controller.visibleSessions.count == 1 ? "" : "s")"
                    )
                case .users:
                    Text("\(controller.visibleUsers.count) account\(controller.visibleUsers.count == 1 ? "" : "s")")
                case .variables:
                    Text(
                        "\(controller.visibleVariables.count) setting\(controller.visibleVariables.count == 1 ? "" : "s")"
                    )
                }
                Spacer()
                if let at = controller.refreshedAt {
                    Text("Refreshed \(at.formatted(date: .omitted, time: .standard))")
                }
                if controller.isLoading { ProgressView().controlSize(.mini) }
            }
        }
        .task {
            if controller.initialPane == "users" {
                pane = .users
                controller.initialPane = nil
                await controller.loadUsers()
            } else {
                await controller.loadSessions()
            }
            if controller.wantsNewUserSheet {
                controller.wantsNewUserSheet = false
                userEditor = UserEditorRequest(mode: .create, database: controller.focusDatabase)
            }
        }
        .onChange(of: pane) { _, new in
            Task {
                switch new {
                case .sessions: await controller.loadSessions()
                case .users: await controller.loadUsers()
                case .variables: await controller.loadVariables()
                }
            }
        }
        .onDisappear { controller.stopPolling() }
        .sheet(item: $userEditor) { request in
            UserEditorSheet(request: request, controller: controller) { userEditor = nil }
        }
        .sheet(item: $droppingUser) { user in
            DestructiveConfirmationView(
                confirmation: DestructiveConfirmation(
                    title: "Drop user “\(user.id)”?",
                    message:
                        "The account and its grants are removed from the server. Objects it owns are left alone, and the server refuses if any depend on it."
                        + (controller.productionName.map { " This is the production connection “\($0)”." } ?? ""),
                    requiredTypedName: controller.productionName,
                    confirmTitle: "Drop User",
                    action: {
                        let request = UserRequest(name: user.name, host: user.host ?? "%")
                        if let failure = await controller.runUserStatements([
                            UserOperations.drop(request, dialect: controller.dialect)
                        ]) {
                            controller.report(failure)
                        }
                    }
                ),
                onDismiss: { droppingUser = nil }
            )
        }
        .sheet(item: $terminating) { session in
            DestructiveConfirmationView(
                confirmation: DestructiveConfirmation(
                    title: "End session \(session.id)?",
                    message:
                        "The connection from \(session.user ?? "?") at \(session.clientAddress ?? "?") is closed on the server and whatever it is running is cancelled."
                        + (controller.productionName.map { " This is the production connection “\($0)”." } ?? ""),
                    requiredTypedName: controller.productionName,
                    confirmTitle: "End Session",
                    action: { await controller.terminate(session.id) }
                ),
                onDismiss: { terminating = nil }
            )
        }
    }

    private func reload() async {
        switch pane {
        case .sessions: await controller.loadSessions()
        case .users:
            await controller.loadUsers()
        case .variables:
            await controller.loadVariables()
        }
    }

    // MARK: - Sessions

    private let sessionWidths: [CGFloat?] = [70, 110, 110, 130, 110, 90, nil]

    @ViewBuilder
    private var sessionsPane: some View {
        if controller.visibleSessions.isEmpty, !controller.isLoading {
            EmptyStateView(
                icon: Icon.activity, title: "No sessions to show",
                message: controller.search.isEmpty ? nil : "Nothing matches “\(controller.search)”.")
        } else {
            VStack(spacing: 0) {
                columnHeader(["ID", "User", "Database", "Client", "State", "Duration", "Query"], widths: sessionWidths)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(controller.visibleSessions.enumerated()), id: \.element.id) { index, session in
                            sessionRow(session, index: index)
                        }
                    }
                }
            }
        }
    }

    private func sessionRow(_ session: ServerSessionInfo, index: Int) -> some View {
        let isSelected = controller.selectedSessionID == session.id
        return HStack(spacing: 0) {
            cell(sessionWidths[0]) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Text(session.id).monospacedDigit()
                    if session.isCurrent { Badge(text: "me", color: .accentColor) }
                }
            }
            cell(sessionWidths[1]) { Text(session.user ?? "—") }
            cell(sessionWidths[2]) { Text(session.database ?? "—").foregroundStyle(.secondary) }
            cell(sessionWidths[3]) { Text(session.clientAddress ?? "—").foregroundStyle(.secondary) }
            cell(sessionWidths[4]) {
                Text(session.state ?? "—")
                    .foregroundStyle(
                        session.state?.lowercased().hasPrefix("active") == true || session.state == "Query"
                            ? Color.green : .secondary)
            }
            cell(sessionWidths[5]) { Text(session.duration ?? "—").monospacedDigit().foregroundStyle(.secondary) }
            cell(nil) {
                Text(session.query?.split(whereSeparator: \.isNewline).joined(separator: " ") ?? "")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .frame(height: 26)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.14)
                : (index.isMultiple(of: 2) ? Color.clear : Color(nsColor: .alternatingContentBackgroundColors[1]))
        )
        .contentShape(Rectangle())
        .onTapGesture { controller.selectedSessionID = session.id }
        .help(session.query ?? "")
        .contextMenu {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.query ?? "", forType: .string)
            } label: {
                Label("Copy Query", systemImage: Icon.copy)
            }
            .disabled((session.query ?? "").isEmpty)
            Divider()
            Button(role: .destructive) {
                terminating = session
            } label: {
                Label("End Session…", systemImage: Icon.stop)
            }
            .disabled(session.isCurrent)
        }
    }

    // MARK: - Users

    private let userWidths: [CGFloat?] = [200, 110, 70, 70, 80, 80, nil]

    private var selectedUser: ServerUserInfo? {
        controller.users.first { $0.id == controller.selectedUserID }
    }

    @ViewBuilder
    private var usersPane: some View {
        if controller.visibleUsers.isEmpty {
            EmptyStateView(
                icon: Icon.user, title: "No accounts visible",
                message: "The server shows each account only what it is allowed to see.")
        } else {
            VStack(spacing: 0) {
                columnHeader(
                    ["Name", "Host", "Super", "Login", "Create DB", "Create role", "Attributes"], widths: userWidths)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(controller.visibleUsers.enumerated()), id: \.element.id) { index, user in
                            let isSelected = controller.selectedUserID == user.id
                            HStack(spacing: 0) {
                                cell(userWidths[0]) {
                                    HStack(spacing: DesignTokens.Spacing.xs + 2) {
                                        Image(systemName: Icon.user)
                                            .foregroundStyle(user.isSuperuser ? .red : .secondary)
                                            .frame(width: DesignTokens.Metrics.iconWidth)
                                        Text(user.name)
                                    }
                                }
                                cell(userWidths[1]) { Text(user.host ?? "—").foregroundStyle(.secondary) }
                                cell(userWidths[2]) { flag(user.isSuperuser) }
                                cell(userWidths[3]) { flag(user.canLogin) }
                                cell(userWidths[4]) { flag(user.canCreateDatabase) }
                                cell(userWidths[5]) { flag(user.canCreateRole) }
                                cell(nil) { Text(user.attributes ?? "").foregroundStyle(.secondary) }
                            }
                            .font(.callout)
                            .frame(height: 26)
                            .background(
                                isSelected
                                    ? Color.accentColor.opacity(0.14)
                                    : (index.isMultiple(of: 2)
                                        ? Color.clear : Color(nsColor: .alternatingContentBackgroundColors[1]))
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                controller.selectedUserID = user.id
                                Task { await controller.loadGrants(for: user) }
                            }
                            .onTapGesture(count: 2) {
                                userEditor = UserEditorRequest(mode: .edit(user), database: controller.focusDatabase)
                            }
                            .contextMenu {
                                Button {
                                    userEditor = UserEditorRequest(
                                        mode: .edit(user), database: controller.focusDatabase)
                                } label: {
                                    Label("Edit…", systemImage: Icon.edit)
                                }
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(
                                        controller.grantLines.joined(separator: ";\n"), forType: .string)
                                } label: {
                                    Label("Copy Grants", systemImage: Icon.copy)
                                }
                                .disabled(controller.selectedUserID != user.id || controller.grantLines.isEmpty)
                                Divider()
                                Button(role: .destructive) {
                                    droppingUser = user
                                } label: {
                                    Label("Drop User…", systemImage: Icon.delete)
                                }
                            }
                        }
                    }
                }
                if let user = selectedUser {
                    Divider()
                    grantsPanel(for: user)
                }
            }
        }
    }

    /// What the selected user may do, as the server puts it.
    private func grantsPanel(for user: ServerUserInfo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading(text: "Grants for \(user.id)", trailing: "\(controller.grantLines.count)")
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    if controller.grantLines.isEmpty {
                        Text("No grants reported.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(controller.grantLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.bottom, DesignTokens.Spacing.md)
            }
            .frame(height: 120)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func flag(_ value: Bool) -> some View {
        Image(systemName: value ? "checkmark" : "minus")
            .font(.caption)
            .foregroundStyle(value ? AnyShapeStyle(Color.green) : AnyShapeStyle(.quaternary))
    }

    // MARK: - Variables

    private let variableWidths: [CGFloat?] = [280, 220, 60, 170, nil]

    @ViewBuilder
    private var variablesPane: some View {
        if controller.visibleVariables.isEmpty {
            EmptyStateView(icon: Icon.variable, title: controller.isLoading ? "Reading…" : "No settings to show")
        } else {
            VStack(spacing: 0) {
                columnHeader(["Name", "Value", "Unit", "Category", "Description"], widths: variableWidths)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(controller.visibleVariables.enumerated()), id: \.element.id) { index, variable in
                            HStack(spacing: 0) {
                                cell(variableWidths[0]) {
                                    Text(variable.name).font(.system(.callout, design: .monospaced))
                                }
                                cell(variableWidths[1]) {
                                    Text(variable.value).font(.system(.callout, design: .monospaced))
                                }
                                cell(variableWidths[2]) { Text(variable.unit ?? "").foregroundStyle(.secondary) }
                                cell(variableWidths[3]) { Text(variable.category ?? "").foregroundStyle(.secondary) }
                                cell(nil) { Text(variable.summary ?? "").foregroundStyle(.secondary) }
                            }
                            .font(.callout)
                            .frame(height: 24)
                            .background(
                                index.isMultiple(of: 2)
                                    ? Color.clear : Color(nsColor: .alternatingContentBackgroundColors[1])
                            )
                            .contextMenu {
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(
                                        "\(variable.name) = \(variable.value)", forType: .string)
                                } label: {
                                    Label("Copy", systemImage: Icon.copy)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Shared

    private func columnHeader(_ titles: [String], widths: [CGFloat?]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: widths[index], alignment: .leading)
                    .frame(maxWidth: widths[index] == nil ? .infinity : nil, alignment: .leading)
                    .padding(.horizontal, DesignTokens.Spacing.sm)
            }
        }
        .frame(height: DesignTokens.Metrics.gridHeaderHeight)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func cell<Content: View>(_ width: CGFloat?, @ViewBuilder content: () -> Content) -> some View {
        content()
            .lineLimit(1)
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .padding(.horizontal, DesignTokens.Spacing.sm)
    }
}

/// What the user editor is doing.
struct UserEditorRequest: Identifiable {
    enum Mode {
        case create
        case edit(ServerUserInfo)
    }

    let id = UUID()
    let mode: Mode
    var database: String?
}

/// Creates or changes a user: name and host, password, attributes, and the privileges to
/// grant on one database. The statements are shown before they run.
struct UserEditorSheet: View {
    let request: UserEditorRequest
    @Bindable var controller: ServerActivityController
    let onDismiss: () -> Void

    @State private var user = UserRequest(name: "")
    @State private var databases: [String] = []
    @State private var typedName = ""
    @State private var failure: String?
    @State private var isRunning = false

    private var isCreate: Bool { if case .create = request.mode { true } else { false } }
    private var isMySQL: Bool { controller.dialect == .mysql }

    private var statements: [String] {
        (try?
            (isCreate
            ? UserOperations.create(user, dialect: controller.dialect)
            : UserOperations.alter(user, dialect: controller.dialect))) ?? []
    }

    private var problem: String? {
        if user.name.trimmingCharacters(in: .whitespaces).isEmpty { return "The user needs a name." }
        if isCreate, (user.password ?? "").isEmpty { return "A new user needs a password." }
        if !isCreate, statements.isEmpty { return "Nothing to change yet: set a password or choose privileges." }
        return nil
    }

    var body: some View {
        SheetFrame(
            title: isCreate ? "New User" : "Edit \(user.name)",
            icon: Icon.user,
            subtitle: isCreate
                ? "Creates the account on the server and grants what you choose."
                : "Changes the password or attributes, and adds grants. Existing grants are not revoked here.",
            width: DesignTokens.Metrics.sheetWidth + 40,
            contentInset: 0
        ) {
            VStack(spacing: 0) {
                Form {
                    Section {
                        TextField(isMySQL ? "User" : "Role", text: $user.name).disabled(!isCreate)
                        if isMySQL {
                            TextField("Host", text: $user.host, prompt: Text("% for any host")).disabled(!isCreate)
                        }
                        SecureField(
                            isCreate ? "Password" : "New password",
                            text: Binding(
                                get: { user.password ?? "" }, set: { user.password = $0.isEmpty ? nil : $0 }
                            ), prompt: Text(isCreate ? "Required" : "Leave empty to keep"))
                    } header: {
                        Label("Account", systemImage: Icon.user)
                    }
                    Section {
                        if !isMySQL {
                            Toggle("Can log in", isOn: $user.canLogin)
                            Toggle("Can create databases", isOn: $user.canCreateDatabase)
                            Toggle("Can create roles", isOn: $user.canCreateRole)
                        }
                        Toggle(isOn: $user.isSuperuser) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(isMySQL ? "All privileges on every database" : "Superuser")
                                Text("Everything, everywhere. Rarely what a person needs.").font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Label("Attributes", systemImage: Icon.shield)
                    }
                    Section {
                        Picker(
                            "Database",
                            selection: Binding(
                                get: { user.database ?? "" }, set: { user.database = $0.isEmpty ? nil : $0 }
                            )
                        ) {
                            Text("None").tag("")
                            ForEach(databases, id: \.self) { Text($0).tag($0) }
                        }
                        HStack(spacing: DesignTokens.Spacing.md) {
                            ForEach(DatabasePrivilege.allCases, id: \.self) { privilege in
                                Toggle(
                                    privilege.title,
                                    isOn: Binding(
                                        get: { user.privileges.contains(privilege) },
                                        set: { on in
                                            if on {
                                                user.privileges.insert(privilege)
                                            } else {
                                                user.privileges.remove(privilege)
                                            }
                                            if privilege == .all, on { user.privileges = [.all] }
                                            if privilege != .all, on { user.privileges.remove(.all) }
                                        }
                                    )
                                )
                                .toggleStyle(.checkbox)
                            }
                        }
                        .disabled(user.database == nil)
                        Toggle("With grant option", isOn: $user.grantOption).disabled(user.database == nil)
                    } header: {
                        Label("Privileges on a database", systemImage: Icon.database)
                    } footer: {
                        Text(
                            isMySQL
                                ? "Granted on every table of the database."
                                : "Granted on every table in the public schema, now and for tables created later.")
                    }
                }
                .formStyle(.grouped)
                .frame(height: isMySQL ? 400 : 440)

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    if let problem {
                        Text(problem).font(.caption).foregroundStyle(.secondary)
                    } else {
                        StatementPreview(sql: statements.joined(separator: ";\n") + ";")
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.lg)
                .padding(.bottom, DesignTokens.Spacing.md)

                if let failure {
                    InlineBanner(kind: .error, message: failure) { self.failure = nil }
                }
            }
        } footer: {
            if let production = controller.productionName {
                ProductionGate(connectionName: production, requiresTypedName: true, typed: $typedName)
            }
            Spacer()
            Button("Cancel", action: onDismiss).keyboardShortcut(.cancelAction)
            Button(isRunning ? "Running…" : (isCreate ? "Create User" : "Apply")) { Task { await run() } }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(
                    problem != nil || isRunning
                        || !ProductionGate.passes(
                            productionName: controller.productionName, requiresTypedName: true, typed: typedName)
                )
        }
        .task {
            databases = await controller.databaseNames()
            switch request.mode {
            case .create:
                user = UserRequest(name: "", host: "%", database: request.database)
            case let .edit(existing):
                user = UserRequest(
                    name: existing.name, host: existing.host ?? "%",
                    canLogin: existing.canLogin, isSuperuser: existing.isSuperuser,
                    canCreateDatabase: existing.canCreateDatabase, canCreateRole: existing.canCreateRole,
                    database: request.database
                )
            }
        }
    }

    private func run() async {
        isRunning = true
        defer { isRunning = false }
        if let failure = await controller.runUserStatements(statements) {
            self.failure = failure
        } else {
            onDismiss()
        }
    }
}
