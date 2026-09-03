import DBCore
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

    public func terminate(_ id: String) async {
        do {
            try await read { try await $0.terminateSession(id: id) }
            await loadSessions()
        } catch {
            errorText = (error as? DBError)?.errorDescription ?? String(describing: error)
        }
    }

    public func clearError() { errorText = nil }

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

    public var body: some View {
        VStack(spacing: 0) {
            PaneBar {
                HStack(spacing: DesignTokens.Spacing.xs + 2) {
                    Image(systemName: Icon.connection).foregroundStyle(Color.accentColor)
                    Text("Server").font(.system(size: 13, weight: .semibold))
                }
                BarDivider()
                Picker("Pane", selection: $pane) {
                    ForEach(Pane.allCases) { pane in
                        Label(pane.rawValue, systemImage: pane.icon).tag(pane)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Image(systemName: Icon.search).foregroundStyle(.secondary)
                    TextField("Filter", text: $controller.search).textFieldStyle(.plain)
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
                    Text("\(controller.visibleSessions.count) session\(controller.visibleSessions.count == 1 ? "" : "s")")
                case .users:
                    Text("\(controller.visibleUsers.count) account\(controller.visibleUsers.count == 1 ? "" : "s")")
                case .variables:
                    Text("\(controller.visibleVariables.count) setting\(controller.visibleVariables.count == 1 ? "" : "s")")
                }
                Spacer()
                if let at = controller.refreshedAt {
                    Text("Refreshed \(at.formatted(date: .omitted, time: .standard))")
                }
                if controller.isLoading { ProgressView().controlSize(.mini) }
            }
        }
        .task { await controller.loadSessions() }
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
        .sheet(item: $terminating) { session in
            DestructiveConfirmationView(
                confirmation: DestructiveConfirmation(
                    title: "End session \(session.id)?",
                    message: "The connection from \(session.user ?? "?") at \(session.clientAddress ?? "?") is closed on the server and whatever it is running is cancelled.",
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
            EmptyStateView(icon: Icon.activity, title: "No sessions to show",
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
                    .foregroundStyle(session.state?.lowercased().hasPrefix("active") == true || session.state == "Query" ? Color.green : .secondary)
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
            isSelected ? Color.accentColor.opacity(0.14)
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

    @ViewBuilder
    private var usersPane: some View {
        if controller.visibleUsers.isEmpty {
            EmptyStateView(icon: Icon.user, title: "No accounts visible",
                           message: "The server shows each account only what it is allowed to see.")
        } else {
            VStack(spacing: 0) {
                columnHeader(["Name", "Host", "Super", "Login", "Create DB", "Create role", "Attributes"], widths: userWidths)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(controller.visibleUsers.enumerated()), id: \.element.id) { index, user in
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
                            .background(index.isMultiple(of: 2) ? Color.clear : Color(nsColor: .alternatingContentBackgroundColors[1]))
                        }
                    }
                }
            }
        }
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
                                cell(variableWidths[0]) { Text(variable.name).font(.system(.callout, design: .monospaced)) }
                                cell(variableWidths[1]) { Text(variable.value).font(.system(.callout, design: .monospaced)) }
                                cell(variableWidths[2]) { Text(variable.unit ?? "").foregroundStyle(.secondary) }
                                cell(variableWidths[3]) { Text(variable.category ?? "").foregroundStyle(.secondary) }
                                cell(nil) { Text(variable.summary ?? "").foregroundStyle(.secondary) }
                            }
                            .font(.callout)
                            .frame(height: 24)
                            .background(index.isMultiple(of: 2) ? Color.clear : Color(nsColor: .alternatingContentBackgroundColors[1]))
                            .contextMenu {
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString("\(variable.name) = \(variable.value)", forType: .string)
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
