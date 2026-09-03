import DBCore
import SwiftUI

/// Application entry point. Phase 0: one empty workspace window.
/// The real window structure (sidebar, tab bar, status bar) arrives in Phase 4 (SPEC §10).
@main
struct DBStudioApp: App {
    var body: some Scene {
        WindowGroup("DBStudio") {
            WorkspacePlaceholderView()
        }
        .defaultSize(width: 1100, height: 720)
    }
}

/// Empty workspace shown until Phase 4 replaces it with the real shell.
struct WorkspacePlaceholderView: View {
    var body: some View {
        Color.clear
            .frame(minWidth: 600, minHeight: 400)
    }
}
