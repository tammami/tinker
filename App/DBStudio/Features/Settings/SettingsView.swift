import SwiftUI

/// Settings the app remembers (SPEC §16 Phase 4).
@MainActor
@Observable
public final class AppSettings {
    public var editorFontName = "SF Mono"
    public var editorFontSize = 13.0
    public var nullDisplayText = ""
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

    public var body: some View {
        TabView {
            Form {
                Picker("Editor font", selection: $settings.editorFontName) {
                    ForEach(Self.monospacedFonts, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                Slider(value: $settings.editorFontSize, in: 9 ... 24, step: 1) {
                    Text("Size \(Int(settings.editorFontSize))")
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Editor", systemImage: "text.alignleft") }

            Form {
                TextField("Show NULL as", text: $settings.nullDisplayText)
                Text("Leave empty to copy NULL as an empty field, which is what spreadsheets expect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("Grid", systemImage: "tablecells") }

            Form {
                Toggle("Confirm every write on production connections", isOn: $settings.confirmOnProduction)
                Toggle("Show system schemas in the sidebar", isOn: $settings.showSystemSchemas)
            }
            .formStyle(.grouped)
            .tabItem { Label("Safety", systemImage: "lock.shield") }
        }
        .frame(width: 460, height: 260)
        .onChange(of: settings.editorFontName) { _, _ in Task { await settings.save() } }
        .onChange(of: settings.editorFontSize) { _, _ in Task { await settings.save() } }
        .onChange(of: settings.nullDisplayText) { _, _ in Task { await settings.save() } }
        .onChange(of: settings.confirmOnProduction) { _, _ in Task { await settings.save() } }
        .onChange(of: settings.showSystemSchemas) { _, _ in Task { await settings.save() } }
    }

    static var monospacedFonts: [String] {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        let preferred = ["SF Mono", "Menlo", "Monaco", "Courier New"]
        return preferred.filter { NSFont(name: $0, size: 12) != nil } + names.prefix(40).filter {
            !preferred.contains($0)
        }
    }
}
