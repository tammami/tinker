import Foundation
import Sparkle
import SwiftUI

/// The software updater, over Sparkle 2 (SPEC §2.1).
///
/// Sparkle needs a signed appcast feed and an EdDSA key pair that only whoever ships the
/// app can create. Both come from `Info.plist`, filled in from the `TINKER_APPCAST_URL` and
/// `TINKER_SPARKLE_PUBLIC_KEY` build settings; the project carries the release feed and
/// public key, and `Scripts/release.sh` signs each DMG with the matching private key. A
/// bundle missing either reports that plainly rather than pretending updates work
/// (DECISIONS.md ADR-0023).
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
        /// Sparkle found a newer build and is showing it; `version` is the appcast's.
        case updateAvailable(version: String)
        case failed(String)
    }

    /// `Info.plist` keys Sparkle itself reads.
    public static let feedURLKey = "SUFeedURL"
    public static let publicKeyKey = "SUPublicEDKey"

    /// Sparkle's controller, created only when the bundle carries a feed and a key.
    /// Starting it without them makes Sparkle log an error on every launch.
    private var controller: SPUStandardUpdaterController?
    private var delegate: Delegate?

    public init() {
        refreshConfiguration()
        if isConfigured {
            let delegate = Delegate()
            delegate.owner = self
            self.delegate = delegate
            controller = SPUStandardUpdaterController(
                startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil
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

    /// The running build, as the About panel and the Updates settings show it.
    public static var versionDescription: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// Asks Sparkle to check now and show its own interface. Sparkle ignores the request
    /// while a check is already running, so pressing twice is harmless.
    public func checkForUpdates() {
        guard let controller else {
            status = .notConfigured
            return
        }
        status = .checking
        controller.checkForUpdates(nil)
    }

    /// Whether Sparkle checks on its own schedule. Off until the user turns it on, so a
    /// database client never reaches the network without being asked.
    public var automaticallyChecks: Bool {
        get {
            access(keyPath: \.automaticallyChecks)
            return controller?.updater.automaticallyChecksForUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticallyChecks) {
                controller?.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    /// When Sparkle last completed a check, on this or an earlier launch.
    public var lastCheckDate: Date? { controller?.updater.lastUpdateCheckDate }

    // MARK: - What Sparkle reports

    fileprivate func didFindUpdate(version: String) {
        status = .updateAvailable(version: version)
    }

    fileprivate func didNotFindUpdate() {
        status = .upToDate(checkedAt: Date())
    }

    fileprivate func didFail(_ error: any Error) {
        // Sparkle's own errors carry a sentence meant for the user; "cancelled" is not
        // a failure, it is the user closing the sheet.
        let nsError = error as NSError
        if nsError.domain == SUSparkleErrorDomain, nsError.code == SUError.installationCanceledError.rawValue {
            refreshConfiguration()
            return
        }
        status = .failed(error.localizedDescription)
    }

    /// Sparkle calls its delegate on the main thread, so every callback steps back onto
    /// the actor without a hop. The delegate is a separate object because
    /// `SPUUpdaterDelegate` wants an `NSObject`.
    private final class Delegate: NSObject, SPUUpdaterDelegate {
        weak var owner: Updater?

        nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
            let version = item.displayVersionString
            MainActor.assumeIsolated { owner?.didFindUpdate(version: version) }
        }

        nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
            MainActor.assumeIsolated { owner?.didNotFindUpdate() }
        }

        nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
            MainActor.assumeIsolated { owner?.didFail(error) }
        }
    }
}
