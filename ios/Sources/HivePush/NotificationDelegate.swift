import Foundation
#if canImport(UserNotifications)
import UserNotifications

/// A small `UNUserNotificationCenterDelegate` that shows notifications while the
/// app is open and reports opens to Hive Push.
///
/// ```swift
/// let pushDelegate = HivePushNotificationDelegate { url, userInfo in
///     // route to url (the notification's `url`), if any
/// }
/// UNUserNotificationCenter.current().delegate = pushDelegate   // keep a strong reference
/// ```
///
/// Notifications that are not from Hive Push are passed to `onOpen` too, with a nil url.
public final class HivePushNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let client: () -> HivePush
    private let presentation: UNNotificationPresentationOptions
    private let onOpen: (@MainActor (URL?, [AnyHashable: Any]) -> Void)?

    /// - Parameters:
    ///   - client: the client to report to (default: `HivePush.shared`).
    ///   - presentationOptions: how to show a notification that arrives while the app is open.
    ///   - onOpen: called on the main actor when the user taps a notification.
    public init(
        client: @autoclosure @escaping () -> HivePush = HivePush.shared,
        presentationOptions: UNNotificationPresentationOptions = [.banner, .list, .sound, .badge],
        onOpen: (@MainActor (URL?, [AnyHashable: Any]) -> Void)? = nil
    ) {
        self.client = client
        self.presentation = presentationOptions
        self.onOpen = onOpen
        super.init()
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(presentation)
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                       withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        let client = self.client()
        if response.actionIdentifier == UNNotificationDismissActionIdentifier {
            if let nid = HivePush.notificationId(from: userInfo) {
                Task { _ = try? await client.report(.dismissed, notificationId: nid) }
            }
        } else {
            Task { _ = try? await client.reportOpened(userInfo: userInfo) }
            if let onOpen = onOpen {
                let url = HivePush.url(from: userInfo)
                // userInfo is a plain property list; hand it to the main actor as is.
                nonisolated(unsafe) let info = userInfo
                onMain { onOpen(url, info) }
            }
        }
        completionHandler()
    }
}
#endif

#if canImport(UIKit) && os(iOS)
import UIKit

extension HivePush {
    /// Asks for notification permission and, when granted, asks iOS for a device
    /// token. iOS then calls your app delegate's
    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`, where you
    /// call `register(deviceToken:)`.
    ///
    /// - Returns: whether the user allowed notifications.
    @MainActor
    @discardableResult
    public static func requestAuthorization(options: UNAuthorizationOptions = [.alert, .sound, .badge]) async throws -> Bool {
        let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: options)
        if granted {
            UIApplication.shared.registerForRemoteNotifications()
        }
        return granted
    }
}
#endif
