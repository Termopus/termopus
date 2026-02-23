import UIKit
import Flutter
import UserNotifications
import firebase_core
import firebase_messaging

@main
@objc class AppDelegate: FlutterAppDelegate {

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Register all generated Flutter plugins (Firebase, MobileScanner, etc.)
        GeneratedPluginRegistrant.register(with: self)

        // Register our native SecurityChannel plugin (biometric, crypto, WebSocket, FCM)
        if let registrar = self.registrar(forPlugin: "SecurityChannel") {
            SecurityChannel.register(with: registrar)
        }

        // Register for remote notifications (required for FCM on iOS)
        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // MARK: - APNs Token Forwarding

    /// Forward the APNs device token to Firebase Messaging.
    /// Firebase uses this to map to an FCM registration token.
    override func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Messaging.messaging().apnsToken = deviceToken
        super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
    }

    /// Handle APNs registration failure.
    override func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NSLog("[AppDelegate] Failed to register for remote notifications: \(error.localizedDescription)")
    }

    // MARK: - Background Silent Push

    /// Handle background data-only push notifications (content-available).
    /// This fires when the relay sends a wake push while the app is backgrounded.
    override func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        let type = userInfo["type"] as? String
        let sessionId = userInfo["sessionId"] as? String

        NSLog("[AppDelegate] Background push received: type=\(type ?? "nil"), sessionId=\(sessionId ?? "nil")")

        if type == "wake", let sessionId = sessionId {
            var completionCalled = false
            let callCompletion: () -> Void = {
                guard !completionCalled else { return }
                completionCalled = true
                completionHandler(.newData)
            }

            // Use background task for the full 30s budget
            var bgTask: UIBackgroundTaskIdentifier = .invalid
            bgTask = application.beginBackgroundTask {
                if bgTask != .invalid {
                    application.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }
                callCompletion()
            }

            showLocalNotification(sessionId: sessionId)

            // Notify Flutter side to reconnect
            if let controller = window?.rootViewController as? FlutterViewController {
                let channel = FlutterMethodChannel(
                    name: "app.clauderemote/security",
                    binaryMessenger: controller.binaryMessenger
                )
                channel.invokeMethod("onWakePush", arguments: ["sessionId": sessionId])
            }

            // Give reconnect time to complete, then finish
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                if bgTask != .invalid {
                    application.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }
                callCompletion()
            }
        } else {
            completionHandler(.noData)
        }
    }

    // MARK: - Local Notification

    /// Show a local notification to bring the user back to the app.
    /// Content is generated entirely on-device — never passes through Apple's servers.
    private func showLocalNotification(sessionId: String) {
        let content = UNMutableNotificationContent()
        content.title = "Claude Code"
        content.body = "Action required — tap to respond"
        content.sound = .default
        content.userInfo = ["sessionId": sessionId, "fromPush": true]

        let request = UNNotificationRequest(
            identifier: "claude_code_wake_\(sessionId)",
            content: content,
            trigger: nil  // deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                NSLog("[AppDelegate] Failed to show local notification: \(error.localizedDescription)")
            }
        }
    }
}
