import DBCore
import DBStore
import SwiftUI

/// The connection sheet: one column of sections, each with its icon, and a test log.
public struct ConnectionEditorView: View {
    @State var config: ConnectionConfig
    let isNew: Bool
    let environment: AppEnvironment
    let onSave: (ConnectionConfig) -> Void
    let onCancel: () -> Void

    @State private var password = ""
    @State private var sshPassword = ""
    @State private var sshPassphrase = ""
    @State private var useSSH = false
    @State private var sshAuthKind = SSHAuthKind.key
    @State private var sshKeyPath = "~/.ssh/id_ed25519"
    @State private var jumpHost = ""
    @State private var jumpUser = ""
    @State private var testLog: [String] = []
    @State private var testOutcome: TestOutcome?
    @State private var isTesting = false
    @State private var validationError: String?

    enum TestOutcome { case success, failure }

    enum SSHAuthKind: String, CaseIterable, Identifiable {
        case password, key, agent
        var id: String { rawValue }
        var title: String {
            switch self {
            case .password: "Password"
            case .key: "Key file"
            case .agent: "Agent"
            }
        }
    }

    public init(
        config: ConnectionConfig,
        isNew: Bool,
        environment: AppEnvironment,
        onSave: @escaping (ConnectionConfig) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _config = State(initialValue: config)
        self.isNew = isNew
        self.environment = environment
        self.onSave = onSave
        self.onCancel = onCancel
    }

    public var body: some View {
        SheetFrame(
            title: isNew ? "New Connection" : config.name,
            icon: Icon.connection,
            subtitle: isNew
                ? "Passwords go to your Keychain, never to \(Product.name)'s own files."
                : "\(config.user)@\(config.host):\(config.port)",
            width: DesignTokens.Metrics.sheetWidth + 40,
            contentInset: 0
        ) {
            VStack(spacing: 0) {
                Form {
                    Section {
                        TextField("Name", text: $config.name)
                        Picker("Engine", selection: $config.dialect) {
                            ForEach([SQLDialect.postgresql, .mysql], id: \.self) { dialect in
                                Label {
                                    Text(dialect == .postgresql ? "PostgreSQL" : "MySQL / MariaDB")
                                } icon: {
                                    EngineMark(dialect: dialect, size: 14)
                                }
                                .tag(dialect)
                            }
                        }
                        .onChange(of: config.dialect) { _, dialect in
                            config.port = environment.registry.defaultPort(for: dialect)
                        }
                        HStack(spacing: DesignTokens.Spacing.sm) {
                            TextField("Host", text: $config.host)
                            TextField("Port", value: $config.port, format: .number.grouping(.never))
                                .frame(width: 90)
                        }
                        TextField("User", text: $config.user)
                        SecureField("Password", text: $password)
                        TextField(
                            "Database",
                            text: Binding(
                                get: { config.database ?? "" },
                                set: { config.database = $0.isEmpty ? nil : $0 }
                            ), prompt: Text(config.dialect == .mysql ? "Optional" : "postgres"))
                    } header: {
                        Label("Server", systemImage: Icon.database)
                    }

                    Section {
                        LabeledContent("Colour") {
                            HStack(spacing: DesignTokens.Spacing.sm) {
                                colorSwatch(nil)
                                ForEach(ConnectionColor.allCases, id: \.self) { colorSwatch($0) }
                            }
                        }
                        TextField(
                            "Group",
                            text: Binding(
                                get: { config.groupPath.joined(separator: "/") },
                                set: { config.groupPath = $0.isEmpty ? [] : $0.components(separatedBy: "/") }
                            ), prompt: Text("Work/Staging"))
                        Toggle(isOn: $config.isProduction) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Production")
                                Text("Every write asks for confirmation, and destructive actions need the name typed.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Toggle(isOn: $config.readOnly) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Read-only")
                                Text("Writes are blocked until unlocked with ⌘⇧L.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Label("Appearance and safety", systemImage: Icon.shield)
                    }

                    Section {
                        Picker("Mode", selection: $config.tls.mode) {
                            ForEach(TLSMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        if config.tls.mode.verifiesCertificate {
                            TextField(
                                "CA file",
                                text: Binding(
                                    get: { config.tls.caFile ?? "" },
                                    set: { config.tls.caFile = $0.isEmpty ? nil : $0 }
                                ))
                            TextField(
                                "Server name override",
                                text: Binding(
                                    get: { config.tls.serverNameOverride ?? "" },
                                    set: { config.tls.serverNameOverride = $0.isEmpty ? nil : $0 }
                                ))
                        }
                    } header: {
                        Label("TLS", systemImage: Icon.lock)
                    }

                    Section {
                        Toggle("Connect through an SSH tunnel", isOn: $useSSH)
                        if useSSH {
                            SSHFields(
                                config: $config,
                                authKind: $sshAuthKind,
                                keyPath: $sshKeyPath,
                                password: $sshPassword,
                                passphrase: $sshPassphrase,
                                jumpHost: $jumpHost,
                                jumpUser: $jumpUser
                            )
                        }
                    } header: {
                        Label("SSH", systemImage: "terminal")
                    }

                    Section {
                        TextField(
                            "Statement timeout (seconds, 0 for none)",
                            value: Binding(
                                get: { config.statementTimeout.map { Int($0.components.seconds) } ?? 0 },
                                set: { config.statementTimeout = $0 <= 0 ? nil : .seconds($0) }
                            ), format: .number)
                        TextField(
                            "Application name",
                            text: Binding(
                                get: { config.options[ConnectionConfig.OptionKey.applicationName] ?? Product.name },
                                set: { config.options[ConnectionConfig.OptionKey.applicationName] = $0 }
                            ))
                        if config.dialect == .mysql {
                            Toggle(
                                "Treat tinyint(1) as boolean",
                                isOn: Binding(
                                    get: { config.options[ConnectionConfig.OptionKey.tinyint1IsBool] != "false" },
                                    set: {
                                        config.options[ConnectionConfig.OptionKey.tinyint1IsBool] =
                                            $0 ? "true" : "false"
                                    }
                                ))
                        }
                    } header: {
                        Label("Advanced", systemImage: Icon.settings)
                    }
                }
                .formStyle(.grouped)
                .frame(height: 440)

                if !testLog.isEmpty {
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(testLog.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(DesignTokens.Spacing.md)
                    }
                    .frame(height: 110)
                    .background(Color(nsColor: .textBackgroundColor))
                }

                if let validationError {
                    InlineBanner(kind: .error, message: validationError) { self.validationError = nil }
                }
            }
        } footer: {
            Button {
                Task { await test() }
            } label: {
                Label(isTesting ? "Testing…" : "Test Connection", systemImage: Icon.activity)
            }
            .disabled(isTesting)
            if isTesting { ProgressView().controlSize(.small) }
            if let testOutcome {
                Image(systemName: testOutcome == .success ? Icon.success : Icon.error)
                    .foregroundStyle(testOutcome == .success ? .green : .red)
            }
            Spacer()
            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(isNew ? "Add Connection" : "Save") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .task { await loadSecrets() }
    }

    private func colorSwatch(_ color: ConnectionColor?) -> some View {
        let isSelected = config.color == color
        return Button {
            config.color = color
        } label: {
            ZStack {
                Circle()
                    .fill(color?.swiftUIColor ?? Color.clear)
                    .frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(color == nil ? Color.secondary : .clear, lineWidth: 1))
                if color == nil {
                    Image(systemName: "slash.circle").font(.caption2).foregroundStyle(.secondary)
                }
                if isSelected {
                    Circle().strokeBorder(Color.primary, lineWidth: 2).frame(width: 24, height: 24)
                }
            }
            .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help(color?.displayName ?? "No colour")
        .accessibilityLabel(color?.displayName ?? "No colour")
    }

    func loadSecrets() async {
        useSSH = config.ssh != nil
        if let ssh = config.ssh {
            switch ssh.auth {
            case .password: sshAuthKind = .password
            case let .privateKey(path, _):
                sshAuthKind = .key
                sshKeyPath = path
            case .agent: sshAuthKind = .agent
            }
            if let jump = ssh.jumpHost?.value {
                jumpHost = jump.host
                jumpUser = jump.user
            }
        }
        if let reference = config.passwordRef,
            let stored = try? await environment.secrets.secret(for: reference)
        {
            password = stored
        }
    }

    func validate() -> String? {
        if config.host.trimmingCharacters(in: .whitespaces).isEmpty { return "A host is required" }
        if config.user.trimmingCharacters(in: .whitespaces).isEmpty { return "A user is required" }
        if config.port < 1 || config.port > 65_535 { return "The port must be between 1 and 65535" }
        if useSSH {
            guard let ssh = config.ssh, !ssh.host.isEmpty else { return "An SSH host is required" }
            if sshAuthKind == .key {
                let expanded = (sshKeyPath as NSString).expandingTildeInPath
                if !FileManager.default.fileExists(atPath: expanded) {
                    return "No key file at \(expanded)"
                }
                // A world-readable key is a warning, not a refusal.
                if let attributes = try? FileManager.default.attributesOfItem(atPath: expanded),
                    let permissions = attributes[.posixPermissions] as? NSNumber,
                    permissions.intValue & 0o077 != 0
                {
                    testLog.append("Warning: \(expanded) is readable by other users; ssh may refuse it.")
                }
            }
        }
        return nil
    }

    func buildConfig() -> ConnectionConfig {
        var result = config
        result.name = result.name.trimmingCharacters(in: .whitespaces)
        if result.name.isEmpty { result.name = "\(result.user)@\(result.host)" }
        if password.isEmpty {
            result.passwordRef = nil
        } else {
            result.passwordRef = SecretRef.forConnection(result.id, field: SecretField.password.rawValue)
        }
        if useSSH {
            var ssh = result.ssh ?? SSHConfig(host: "", user: NSUserName(), auth: .agent)
            switch sshAuthKind {
            case .password:
                ssh.auth = .password(SecretRef.forConnection(result.id, field: SecretField.sshPassword.rawValue))
            case .key:
                let passphraseRef =
                    sshPassphrase.isEmpty
                    ? nil
                    : SecretRef.forConnection(result.id, field: SecretField.sshPassphrase.rawValue)
                ssh.auth = .privateKey(path: sshKeyPath, passphrase: passphraseRef)
            case .agent:
                ssh.auth = .agent
            }
            if !jumpHost.isEmpty {
                // The jump host takes the same key as the target: an agent is not available
                // in this build, so `.agent` here would fail every jump-host connection.
                ssh.jumpHost = Box(
                    SSHConfig(
                        host: jumpHost, user: jumpUser.isEmpty ? NSUserName() : jumpUser, auth: ssh.auth
                    ))
            } else {
                ssh.jumpHost = nil
            }
            result.ssh = ssh
        } else {
            result.ssh = nil
        }
        return result
    }

    /// Writes the typed secrets into `store`. On Save that is the Keychain, and a field the
    /// user emptied has its item deleted so the old secret does not linger; Test Connection
    /// uses an in-memory store instead, so a cancelled sheet leaves nothing behind.
    func storeSecrets(for config: ConnectionConfig, in store: any SecretStore, deletingCleared: Bool) async {
        let passwordRef = SecretRef.forConnection(config.id, field: SecretField.password.rawValue)
        if !password.isEmpty {
            try? await store.setSecret(password, for: passwordRef)
        } else if deletingCleared {
            try? await store.deleteSecret(for: passwordRef)
        }
        let sshPasswordRef = SecretRef.forConnection(config.id, field: SecretField.sshPassword.rawValue)
        if useSSH, sshAuthKind == .password, !sshPassword.isEmpty {
            try? await store.setSecret(sshPassword, for: sshPasswordRef)
        } else if deletingCleared {
            try? await store.deleteSecret(for: sshPasswordRef)
        }
        let passphraseRef = SecretRef.forConnection(config.id, field: SecretField.sshPassphrase.rawValue)
        if useSSH, sshAuthKind == .key, !sshPassphrase.isEmpty {
            try? await store.setSecret(sshPassphrase, for: passphraseRef)
        } else if deletingCleared {
            try? await store.deleteSecret(for: passphraseRef)
        }
    }

    /// A field still being typed in commits its text when it stops being first responder,
    /// which a click on Save does not do by itself: the value typed last (the database,
    /// as it happens) would be missing from what is saved. So editing ends first, and the
    /// config is read on the next turn of the run loop, once the field has written back.
    func save() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        Task { @MainActor in
            await Task.yield()
            if let error = validate() {
                validationError = error
                return
            }
            let result = buildConfig()
            await storeSecrets(for: result, in: environment.secrets, deletingCleared: !isNew)
            onSave(result)
        }
    }

    func test() async {
        if let error = validate() {
            validationError = error
            return
        }
        isTesting = true
        testOutcome = nil
        testLog = ["Starting…"]
        defer { isTesting = false }

        let candidate = buildConfig()
        // The typed secrets, in memory only: nothing reaches the Keychain until Save.
        let scratch = EphemeralSecretStore()
        await storeSecrets(for: candidate, in: scratch, deletingCleared: false)
        let session = ConnectionSession(
            config: candidate,
            registry: environment.registry,
            secrets: scratch,
            tunnelProvider: environment.tunnelProvider
        )
        let recorder = TestLogRecorder()
        let result = await session.testConnection { stage, message in
            recorder.append("[\(stage.rawValue)] \(message)")
        }
        testLog = recorder.lines
        switch result {
        case let .success(version):
            testLog.append("✓ \(version.rawString)")
            testOutcome = .success
        case let .failure(error):
            testLog.append("✗ \(error.errorDescription ?? String(describing: error))")
            testOutcome = .failure
        }
        await session.disconnect()
    }
}

/// Collects the stage-by-stage messages Test Connection reports.
final class TestLogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.lock()
        storage.append(line)
        lock.unlock()
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// The SSH half of the connection form, split out to keep the type-checker fast.
struct SSHFields: View {
    @Binding var config: ConnectionConfig
    @Binding var authKind: ConnectionEditorView.SSHAuthKind
    @Binding var keyPath: String
    @Binding var password: String
    @Binding var passphrase: String
    @Binding var jumpHost: String
    @Binding var jumpUser: String

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            TextField("Host", text: binding(\.host, default: ""))
            TextField("Port", value: binding(\.port, default: 22), format: .number.grouping(.never))
                .frame(width: 90)
        }
        TextField("User", text: binding(\.user, default: NSUserName()))
        Picker("Authentication", selection: $authKind) {
            ForEach(ConnectionEditorView.SSHAuthKind.allCases) { kind in
                Text(kind.title).tag(kind)
            }
        }
        switch authKind {
        case .password:
            SecureField("SSH password", text: $password)
        case .key:
            HStack {
                TextField("Key file", text: $keyPath)
                Button("Choose…") { chooseKeyFile() }
            }
            SecureField("Passphrase (if the key has one)", text: $passphrase)
        case .agent:
            Label("Agent authentication is not available in this build; choose a key file.", systemImage: Icon.warning)
                .font(.caption)
                .foregroundStyle(.orange)
        }
        Picker("Host key policy", selection: binding(\.knownHostsPolicy, default: .acceptNew)) {
            Text("Strict").tag(KnownHostsPolicy.strict)
            Text("Accept new hosts").tag(KnownHostsPolicy.acceptNew)
            Text("Ignore (insecure)").tag(KnownHostsPolicy.ignore)
        }
        DisclosureGroup("Jump host") {
            TextField("Host", text: $jumpHost)
            TextField("User", text: $jumpUser)
        }
    }

    func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url { keyPath = url.path }
    }

    /// Reads and writes one field of the optional SSH config, creating it on first write.
    func binding<Value>(
        _ keyPath: WritableKeyPath<SSHConfig, Value>,
        default fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: { config.ssh?[keyPath: keyPath] ?? fallback },
            set: { value in
                var ssh = config.ssh ?? SSHConfig(host: "", user: NSUserName(), auth: .agent)
                ssh[keyPath: keyPath] = value
                config.ssh = ssh
            }
        )
    }
}
