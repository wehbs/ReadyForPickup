//
//  NotificationManager.swift
//  ReadyForPickup
//
//  Created by Worth Baker on 11/8/21.
//

import AppKit
import Foundation
import os
import UserNotifications

private let logger = Logger(subsystem: "com.wehbs.ReadyForPickup", category: "Notifications")

/// The app-wide switch for Mac notifications (UserDefaults
/// `macNotificationsEnabled`, on by default). macOS's own permission
/// (System Settings > Notifications) is separate: see NotificationManager.
enum MacNotificationSettings {
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "macNotificationsEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "macNotificationsEnabled") }
    }
}

// Sendable (no stored state) rather than @MainActor: UserNotifications
// calls the delegate method and completion handlers on its own queue.
final class NotificationManager: NSObject, Sendable {

    static let shared = NotificationManager()

    /// Makes this the notification center's delegate, so banners also show
    /// while the app is in front. Call once at launch.
    func configure() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// What macOS currently allows this app.
    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Shows macOS's permission prompt. macOS asks only once: after that,
    /// only System Settings can change the answer (openSystemSettings).
    func requestAuthorization() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            if granted == false {
                logger.info("Notifications are disabled for this app")
            }
        } catch {
            logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Opens System Settings > Notifications at this app's entry.
    @MainActor static func openSystemSettings() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.wehbs.ReadyForPickup"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)") {
            NSWorkspace.shared.open(url)
        }
    }

    func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound.default
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        
        let uuidString = UUID().uuidString
        let request = UNNotificationRequest(identifier: uuidString,content: content, trigger: trigger)
        
        // Schedule the request with the system.
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.add(request) { (error) in
            if let error {
                logger.error("Couldn't post a notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Swift.Void) {
        completionHandler( [.banner, .badge, .sound])
    }
}
