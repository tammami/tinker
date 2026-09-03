import SwiftUI

/// Settings the app remembers.
@MainActor
@Observable
public final class AppSettings {
    public var editorFontName = "SF Mono"
    public var editorFontSize = 13.0
    public var nullDisplayText = "" {
        didSet { environment.nullDisplayText = nullDisplayText }
    }
    public var confirmOnProduction = true
    public var showSystemSchemas = false

    private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public func load() async {
        editorFontName = await environment.setting("editor.fontName", default: "SF Mono")
        editorFontSize = await environment.setting("editor.fontSize", default: 13.0)
        nullDisplayText = await environment.setting("grid.nullText", default: "")
        confirmOnProduction = await environment.setting("safety.confirmOnProduction", default: true)
        showSystemSchemas = await environment.setting("sidebar.showSystemSchemas", default: false)
    }

    public func save() async {
        await environment.setSetting(editorFontName, for: "editor.fontName")
        await environment.setSetting(editorFontSize, for: "editor.fontSize")
        await environment.setSetting(nullDisplayText, for: "grid.nullText")
        await environment.setSetting(confirmOnProduction, for: "safety.confirmOnProduction")
        await environment.setSetting(showSystemSchemas, for: "sidebar.showSystemSchemas")
    }
}

public struct SettingsView: View {
    @Bindable var settings: AppSettings
    let crashReporter: CrashReporter
    let updater: Updater

    @State private var collectDiagnostics = false
    @State private var reportCount = 0

    public init(settings: AppSettings, crashReporter: CrashReporter, updater: Updater) {
        self.settings = settings
        self.crashReporter = crashReporter
        self.updater = updater
    }

    public var body: some View {
        TabView {
            Form {
                Section {
                    Picker("Font", selection: $settings.editorFontName) {
                        ForEach(Self.monospacedFonts, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    LabeledContent("Size") {
                        HStack(spacing: DesignTokens.Spacing.sm) {
                            Slider(value: $settings.editorFontSize, in: 9 ... 24, step: 1)
                            Text("\(Int(settings.editorFontSize)) pt").monospacedDigit().frame(width: 40, alignment: .trailing)
                        }
                    }
                    LabeledContent("Preview") {
                        Text("SELECT id, name FROM users WHERE id = $1;")
                            .font(Font(DesignTokens.Fonts.editor(name: settings.editorFontName, size: CGFloat(settings.editorFontSize))))
                    }
                } header: {
                    Label("SQL editor", systemImage: Icon.query)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Editor", systemImage: Icon.query) }

            Form {
                Section {
                    TextField("Show NULL as", text: $settings.nullDisplayText, prompt: Text("empty"))
                } header: {
                    Label("Copy and export", systemImage: Icon.copy)
                } footer: {
                    Text("Leave empty to copy NULL as an empty field, which is what spreadsheets expect.")
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Grid", systemImage: Icon.data) }

            Form {
                Section {
                    Toggle("Confirm every write on production connections", isOn: $settings.confirmOnProduction)
                    Toggle("Show system schemas in the sidebar", isOn: $settings.showSystemSchemas)
                } header: {
                    Label("Safety", systemImage: Icon.shield)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Safety", systemImage: Icon.shield) }

            Form {
                Section {
                    Toggle("Save diagnostic reports on this Mac", isOn: $collectDiagnostics)
                        .onChange(of: collectDiagnostics) { _, value in
                            Task { await crashReporter.setEnabled(value) }
                        }
                    LabeledContent("Saved reports") {
                        HStack(spacing: DesignTokens.Spacing.sm) {
                            Text("\(reportCount)").monospacedDigit()
                            Button("Show in Finder") { CrashReporter.revealReportsInFinder() }
                            Button("Delete All", role: .destructive) {
                                CrashReporter.deleteAllReports()
                                reportCount = CrashReporter.existingReports().count
                            }
                            .disabled(reportCount == 0)
                        }
                    }
                } header: {
                    Label("Diagnostics", systemImage: "stethoscope")
                } footer: {
                    Text("Reports are written to Application Support and never sent anywhere. They record the app version, the system version and a stack trace; never SQL, values or credentials.")
                }
                Section {
                    LabeledContent("Updates") {
                        Text(Self.describe(updater.status)).foregroundStyle(.secondary)
                    }
                } header: {
                    Label("Updates", systemImage: Icon.refresh)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .task {
            reportCount = CrashReporter.existingReports().count
        }
        .frame(width: 520, height: 320)
        .onChange(of: settings.editorFontName) { _, _ in Task { await settings.save() } }
        .onChange(of: settings.editorFontSize) { _, _ in Task { await settings.save() } }
        .onChange(of: settings.nullDisplayText) { _, _ in Task { await settings.save() } }
        .onChange(of: settings.confirmOnProduction) { _, _ in Task { await settings.save() } }
        .onChange(of: settings.showSystemSchemas) { _, _ in Task { await settings.save() } }
    }

    static func describe(_ status: Updater.Status) -> String {
        switch status {
        case .notConfigured: "Not configured in this build"
        case let .idle(feed): feed.host ?? feed.absoluteString
        case .checking: "Checking…"
        case let .upToDate(checkedAt): "Up to date, checked \(checkedAt.formatted(date: .omitted, time: .shortened))"
        case let .failed(message): message
        }
    }

    static var monospacedFonts: [String] {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        let preferred = ["SF Mono", "Menlo", "Monaco", "Courier New"]
        return preferred.filter { NSFont(name: $0, size: 12) != nil } + names.prefix(40).filter {
            !preferred.contains($0)
        }
    }
}
