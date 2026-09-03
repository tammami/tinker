import Foundation
import Sparkle
import SwiftUI

/// The software updater, over Sparkle 2 (SPEC §2.1).
///
/// Sparkle needs a signed appcast feed and an EdDSA key pair that only whoever ships the
/// app can create. Both are read from `Info.plist`, which `Scripts/release.sh` fills in
/// from the environment; a development build has neither and reports that plainly rather
/// than pretending updates work (DECISIONS.md ADR-0023).
@MainActor
@Observable
public final class Updater {
    public private(set) var status: Status = .notConfigured

    public enum Status: Equatable {
        /// No appcast URL or public key in the bundle: a development build.
        case notConfigured
        case idle(feed: URL)
        case checking
        case upToDate(checkedAt: Date)
        case failed(String)
    }

    /// `Info.plist` keys Sparkle itself reads.
    public static let feedURLKey = "SUFeedURL"
    public static let publicKeyKey = "SUPublicEDKey"

    /// Sparkle's controller, created only when the bundle carries a feed and a key.
    /// Starting it without them makes Sparkle log an error on every launch.
    private var controller: SPUStandardUpdaterController?

    public init() {
        refreshConfiguration()
        if isConfigured {
            controller = SPUStandardUpdaterController(
                startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
            )
        }
    }

    public var isConfigured: Bool {
        if case .notConfigured = status { return false }
        return true
    }

    public var feedURL: URL? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: Self.feedURLKey) as? String,
              !text.isEmpty
        else { return nil }
        return URL(string: text)
    }

    public var publicKey: String? {
        let key = Bundle.main.object(forInfoDictionaryKey: Self.publicKeyKey) as? String
        return (key?.isEmpty ?? true) ? nil : key
    }

    private func refreshConfiguration() {
        guard let feedURL, publicKey != nil else {
            status = .notConfigured
            return
        }
        status = .idle(feed: feedURL)
    }

    /// What the menu item should say.
    public var menuTitle: String {
        isConfigured ? "Check for Updates…" : "Check for Updates (not configured)"
    }

    /// Asks Sparkle to check now and show its own interface.
    public func checkForUpdates() {
        guard let controller else {
            status = .notConfigured
            return
        }
        status = .checking
        controller.checkForUpdates(nil)
        status = .upToDate(checkedAt: Date())
    }

    /// Whether Sparkle checks on its own schedule. Off until the user turns it on, so a
    /// database client never reaches the network without being asked.
    public var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }
}
