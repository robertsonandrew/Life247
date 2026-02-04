//
//  NotificationService.swift
//  Life247
//
//  Created by Andrew Robertson on 1/15/26.
//

import Foundation
import UserNotifications
import Combine

/// Handles local notifications for drive events.
/// No @MainActor - notifications don't require main thread.
final class NotificationService: ObservableObject {
    static let shared = NotificationService()
    
    @Published var notifyOnStart: Bool {
        didSet { UserDefaults.standard.set(notifyOnStart, forKey: "notifyOnDriveStart") }
    }
    @Published var notifyOnEnd: Bool {
        didSet { UserDefaults.standard.set(notifyOnEnd, forKey: "notifyOnDriveEnd") }
    }
    
    private let center = UNUserNotificationCenter.current()
    
    private init() {
        // Default both notifications to ON if not explicitly set
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "notifyOnDriveStart") == nil {
            defaults.set(true, forKey: "notifyOnDriveStart")
        }
        if defaults.object(forKey: "notifyOnDriveEnd") == nil {
            defaults.set(true, forKey: "notifyOnDriveEnd")
        }
        self.notifyOnStart = defaults.bool(forKey: "notifyOnDriveStart")
        self.notifyOnEnd = defaults.bool(forKey: "notifyOnDriveEnd")
    }
    
    // MARK: - Permission
    
    /// Request notification permission. Returns true if granted.
    func requestPermissionIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()
        
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                return false
            }
        @unknown default:
            return false
        }
    }
    
    // MARK: - Drive Notifications
    
    /// Send notification when drive starts.
    func sendDriveStarted() {
        guard notifyOnStart else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "Drive Started"
        content.body = "Recording your trip."
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: "drive.started",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        
        center.add(request)
    }
    
    /// Send notification when drive ends with summary.
    func sendDriveEnded(distance: String, duration: String) {
        guard notifyOnEnd else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "Drive Complete"
        content.body = "\(distance) • \(duration)"
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: "drive.ended",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        
        center.add(request)
    }
}
