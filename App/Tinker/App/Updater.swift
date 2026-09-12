import Foundation
import Sparkle
import SwiftUI
import UserNotifications

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
                startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: delegate
            )
            // A tap on the notification has to reach us, and the banner should appear even
            // while Tinker is the app in front.
            UNUserNotificationCenter.current().delegate = delegate
            if automaticallyChecks { requestNotificationPermission() }
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
            // Only now: nothing is ever announced until checks run on their own, so an app
            // whose owner never turns this on never asks for notifications either.
            if newValue { requestNotificationPermission() }
        }
    }

    /// When Sparkle last completed a check, on this or an earlier launch.
    public var lastCheckDate: Date? { controller?.updater.lastUpdateCheckDate }

    // MARK: - Notifications

    /// The one notification Tinker posts, replaced rather than stacked when a newer
    /// version turns up before the last one was acted on.
    nonisolated static let updateNotificationIdentifier = "tinker.update-available"

    /// Asks once for permission to post notifications. macOS remembers the answer, so a
    /// second call after a refusal is silent rather than a second prompt.
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Announces a version found by a check the user did not ask for.
    fileprivate func postUpdateNotification(version: String) {
        let content = UNMutableNotificationContent()
        content.title = "\(Product.name) \(version) is available"
        content.body = "You have \(Self.versionDescription). Click to see what changed and install it."
        let request = UNNotificationRequest(
            identifier: Self.updateNotificationIdentifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Takes the notification back once the update is on screen, so Notification Centre
    /// does not keep offering something already being dealt with.
    fileprivate func clearUpdateNotification() {
        let centre = UNUserNotificationCenter.current()
        centre.removeDeliveredNotifications(withIdentifiers: [Self.updateNotificationIdentifier])
        centre.removePendingNotificationRequests(withIdentifiers: [Self.updateNotificationIdentifier])
    }

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
    private final class Delegate: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate,
        UNUserNotificationCenterDelegate
    {
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

        // MARK: Gentle reminders

        /// Tinker announces scheduled updates itself, so Sparkle hands them over rather
        /// than opening its window over whatever the user is doing.
        nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

        nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
            _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
        ) -> Bool {
            // Never Sparkle's window for a check nobody asked for, not even when the app
            // was just launched and Sparkle proposes immediate focus (`immediateFocus`).
            // An update is not urgent enough to take over the screen; it is announced, and
            // the window opens when the notification is clicked.
            false
        }

        nonisolated func standardUserDriverWillHandleShowingUpdate(
            _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
        ) {
            // A check the user asked for already has their attention, and if Sparkle is
            // showing the window itself there is nothing to announce; only an update the
            // delegate is left holding becomes a notification.
            guard !state.userInitiated, !handleShowingUpdate else { return }
            let version = update.displayVersionString
            MainActor.assumeIsolated { owner?.postUpdateNotification(version: version) }
        }

        nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
            MainActor.assumeIsolated { owner?.clearUpdateNotification() }
        }

        nonisolated func standardUserDriverWillFinishUpdateSession() {
            MainActor.assumeIsolated { owner?.clearUpdateNotification() }
        }

        // MARK: The notification

        /// Clicking the notification is the user asking to see the update, which is what
        /// a check does: Sparkle already has the appcast item and shows it at once.
        nonisolated func userNotificationCenter(
            _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
            withCompletionHandler completionHandler: @escaping () -> Void
        ) {
            let isOurs = response.notification.request.identifier == Updater.updateNotificationIdentifier
            let isClick = response.actionIdentifier == UNNotificationDefaultActionIdentifier
            if isOurs, isClick {
                Task { @MainActor [weak self] in
                    NSApp.activate(ignoringOtherApps: true)
                    self?.owner?.checkForUpdates()
                }
            }
            completionHandler()
        }

        /// Banners appear even while Tinker is the app in front; without this macOS keeps
        /// them for Notification Centre and the user sees nothing.
        nonisolated func userNotificationCenter(
            _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
        ) {
            completionHandler([.banner, .sound])
        }
    }
}
