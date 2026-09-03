import DBCore
import DBStore
import SwiftUI

/// The connection sheet (SPEC §11.2).
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
    @State private var isTesting = false
    @State private var validationError: String?

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
        VStack(spacing: 0) {
            Form {
                Section("General") {
                    TextField("Name", text: $config.name)
                    Picker("Colour", selection: $config.color) {
                        Text("None").tag(ConnectionColor?.none)
                        ForEach(ConnectionColor.allCases, id: \.self) { color in
                            Text(color.displayName).tag(ConnectionColor?.some(color))
                        }
                    }
                    TextField("Group", text: Binding(
                        get: { config.groupPath.joined(separator: "/") },
                        set: { config.groupPath = $0.isEmpty ? [] : $0.components(separatedBy: "/") }
                    ))
                    Picker("Type", selection: $config.dialect) {
                        Text("PostgreSQL").tag(SQLDialect.postgresql)
                        Text("MySQL / MariaDB").tag(SQLDialect.mysql)
                    }
                    .onChange(of: config.dialect) { _, dialect in
                        config.port = environment.registry.defaultPort(for: dialect)
                    }
                    TextField("Host", text: $config.host)
                    TextField("Port", value: $config.port, format: .number.grouping(.never))
                    TextField("User", text: $config.user)
                    SecureField("Password", text: $password)
                    TextField("Database", text: Binding(
                        get: { config.database ?? "" },
                        set: { config.database = $0.isEmpty ? nil : $0 }
                    ))
                }

                Section("TLS") {
                    Picker("Mode", selection: $config.tls.mode) {
                        ForEach(TLSMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    TextField("CA file", text: Binding(
                        get: { config.tls.caFile ?? "" },
                        set: { config.tls.caFile = $0.isEmpty ? nil : $0 }
                    ))
                    TextField("Server name override", text: Binding(
                        get: { config.tls.serverNameOverride ?? "" },
                        set: { config.tls.serverNameOverride = $0.isEmpty ? nil : $0 }
                    ))
                }

                Section("SSH") {
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
                }

                Section("Advanced") {
                    TextField("Statement timeout (seconds, 0 for none)", value: Binding(
                        get: { config.statementTimeout.map { Int($0.components.seconds) } ?? 0 },
                        set: { config.statementTimeout = $0 <= 0 ? nil : .seconds($0) }
                    ), format: .number)
                    TextField("Application name", text: Binding(
                        get: { config.options[ConnectionConfig.OptionKey.applicationName] ?? "DBStudio" },
                        set: { config.options[ConnectionConfig.OptionKey.applicationName] = $0 }
                    ))
                    if config.dialect == .mysql {
                        Toggle("Treat tinyint(1) as boolean", isOn: Binding(
                            get: { config.options[ConnectionConfig.OptionKey.tinyint1IsBool] != "false" },
                            set: { config.options[ConnectionConfig.OptionKey.tinyint1IsBool] = $0 ? "true" : "false" }
                        ))
                    }
                    Toggle("Read-only", isOn: $config.readOnly)
                    Toggle("Production", isOn: $config.isProduction)
                }
            }
            .formStyle(.grouped)

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
                    .padding(8)
                }
                .frame(height: 110)
            }

            if let validationError {
                ErrorBanner(message: validationError) { self.validationError = nil }
            }

            Divider()
            HStack {
                Button("Test Connection") { Task { await test() } }
                    .disabled(isTesting)
                if isTesting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 620)
        .task { await loadSecrets() }
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
           let stored = try? await environment.secrets.secret(for: reference) {
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
                // A world-readable key is a warning, not a refusal (SPEC §11.2).
                if let attributes = try? FileManager.default.attributesOfItem(atPath: expanded),
                   let permissions = attributes[.posixPermissions] as? NSNumber,
                   permissions.intValue & 0o077 != 0 {
                    testLog.append("Warning: \(expanded) is readable by other users; ssh may refuse it.")
                }
            }
        }
        return nil
    }

    func buildConfig() -> ConnectionConfig {
        var result = config
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
                let passphraseRef = sshPassphrase.isEmpty
                    ? nil
                    : SecretRef.forConnection(result.id, field: SecretField.sshPassphrase.rawValue)
                ssh.auth = .privateKey(path: sshKeyPath, passphrase: passphraseRef)
            case .agent:
                ssh.auth = .agent
            }
            if !jumpHost.isEmpty {
                ssh.jumpHost = Box(SSHConfig(
                    host: jumpHost, user: jumpUser.isEmpty ? NSUserName() : jumpUser, auth: .agent
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

    func storeSecrets(for config: ConnectionConfig) async {
        if !password.isEmpty, let reference = config.passwordRef {
            try? await environment.secrets.setSecret(password, for: reference)
        }
        if useSSH, sshAuthKind == .password, !sshPassword.isEmpty {
            try? await environment.secrets.setSecret(
                sshPassword,
                for: SecretRef.forConnection(config.id, field: SecretField.sshPassword.rawValue)
            )
        }
        if useSSH, sshAuthKind == .key, !sshPassphrase.isEmpty {
            try? await environment.secrets.setSecret(
                sshPassphrase,
                for: SecretRef.forConnection(config.id, field: SecretField.sshPassphrase.rawValue)
            )
        }
    }

    func save() {
        if let error = validate() {
            validationError = error
            return
        }
        let result = buildConfig()
        Task {
            await storeSecrets(for: result)
            onSave(result)
        }
    }

    func test() async {
        if let error = validate() {
            validationError = error
            return
        }
        isTesting = true
        testLog = ["Starting…"]
        defer { isTesting = false }

        let candidate = buildConfig()
        await storeSecrets(for: candidate)
        let session = ConnectionSession(
            config: candidate,
            registry: environment.registry,
            secrets: environment.secrets,
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
        case let .failure(error):
            testLog.append("✗ \(error.errorDescription ?? String(describing: error))")
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
        TextField("Host", text: binding(\.host, default: ""))
        TextField("Port", value: binding(\.port, default: 22), format: .number.grouping(.never))
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
            Text("Agent authentication is not available in this build; choose a key file.")
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
