import DBTunnel
import Foundation

/// The app's answer to a host key nobody has seen before (ADR-0046).
///
/// `ssh` shows the fingerprint and asks; Tinker used to accept silently and append the
/// key to the user's own `~/.ssh/known_hosts`, so a first contact through Tinker also
/// decided what the user's `ssh` would trust. Now the sheet asks, and an accepted key is
/// written to Tinker's own file. The user's file is still read, so a host `ssh` already
/// trusts needs no question.
enum HostKeyPrompt {
    /// Tinker's own known hosts: read alongside the user's, written instead of it.
    static var recordPath: String {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("\(Product.name)/known_hosts").path
    }

    static var trust: HostKeyTrust {
        HostKeyTrust(
            readPaths: [KnownHostsFile.defaultPath, recordPath],
            recordPath: recordPath,
            confirmation: { presentation in await confirm(presentation) }
        )
    }

    /// Shows the fingerprint in the frontmost workspace's confirmation sheet and waits
    /// for the answer. With no window to ask in — a headless run — the key is refused:
    /// silently trusting an unknown host is what this exists to stop.
    @MainActor
    static func confirm(_ presentation: HostKeyPresentation) async -> Bool {
        guard let workspace = CommandCenter.shared.current?.workspace else { return false }
        return await withCheckedContinuation { continuation in
            let port = presentation.port == 22 ? "" : ":\(presentation.port)"
            workspace.confirmation = DestructiveConfirmation(
                title: "Trust \(presentation.host)\(port)?",
                message:
                    "This SSH server is not in your known hosts. Its \(presentation.keyType) key has the fingerprint\n\n"
                    + "\(presentation.fingerprint)\n\n"
                    + "Compare it with what the server's administrator published before you continue. "
                    + "Accepting records the key in Tinker's own known hosts, not in ~/.ssh/known_hosts.",
                confirmTitle: "Trust and Connect",
                action: { continuation.resume(returning: true) },
                onCancel: { continuation.resume(returning: false) }
            )
        }
    }
}
