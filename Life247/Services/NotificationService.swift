//
//  NotificationService.swift
//  Life247
//
//  Created by Andrew Robertson on 1/15/26.
//

import Foundation
import UserNotifications
import Combine
import AVFoundation

enum NotificationSoundOption: String, CaseIterable, Hashable {
    case triTone = "TriTone.wav"
    case chord = "Chord.wav"
    case glass = "Glass.wav"
    case bell = "Bell.wav"
    case electronic = "Electronic.wav"

    var label: String {
        switch self {
        case .triTone: return "Tri-tone"
        case .chord: return "Chord"
        case .glass: return "Glass"
        case .bell: return "Bell"
        case .electronic: return "Electronic"
        }
    }

    var notificationSound: UNNotificationSound {
        .soundNamed(UNNotificationSoundName(rawValue: rawValue))
    }
}

/// Handles local notifications for drive events.
/// No @MainActor - notifications don't require main thread.
final class NotificationService: ObservableObject {
    static let shared = NotificationService()

    private enum Keys {
        static let notifyOnDriveStart = "notifyOnDriveStart"
        static let notifyOnDriveEnd = "notifyOnDriveEnd"
        static let notifyDriveStartSound = "notifyDriveStartSound"
        static let notifyDriveEndSound = "notifyDriveEndSound"
    }
    
    @Published var notifyOnStart: Bool {
        didSet { UserDefaults.standard.set(notifyOnStart, forKey: Keys.notifyOnDriveStart) }
    }
    @Published var notifyOnEnd: Bool {
        didSet { UserDefaults.standard.set(notifyOnEnd, forKey: Keys.notifyOnDriveEnd) }
    }
    @Published var startSound: NotificationSoundOption {
        didSet { UserDefaults.standard.set(startSound.rawValue, forKey: Keys.notifyDriveStartSound) }
    }
    @Published var endSound: NotificationSoundOption {
        didSet { UserDefaults.standard.set(endSound.rawValue, forKey: Keys.notifyDriveEndSound) }
    }
    
    private let center = UNUserNotificationCenter.current()
    private var previewPlayer: AVAudioPlayer?
    
    private init() {
        // Default both notifications to ON if not explicitly set
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Keys.notifyOnDriveStart) == nil {
            defaults.set(true, forKey: Keys.notifyOnDriveStart)
        }
        if defaults.object(forKey: Keys.notifyOnDriveEnd) == nil {
            defaults.set(true, forKey: Keys.notifyOnDriveEnd)
        }
        if defaults.object(forKey: Keys.notifyDriveStartSound) == nil {
            defaults.set(NotificationSoundOption.triTone.rawValue, forKey: Keys.notifyDriveStartSound)
        }
        if defaults.object(forKey: Keys.notifyDriveEndSound) == nil {
            defaults.set(NotificationSoundOption.chord.rawValue, forKey: Keys.notifyDriveEndSound)
        }
        self.notifyOnStart = defaults.bool(forKey: Keys.notifyOnDriveStart)
        self.notifyOnEnd = defaults.bool(forKey: Keys.notifyOnDriveEnd)

        let startRaw = defaults.string(forKey: Keys.notifyDriveStartSound) ?? NotificationSoundOption.triTone.rawValue
        self.startSound = NotificationSoundOption(rawValue: startRaw) ?? .triTone
        let endRaw = defaults.string(forKey: Keys.notifyDriveEndSound) ?? NotificationSoundOption.chord.rawValue
        self.endSound = NotificationSoundOption(rawValue: endRaw) ?? .chord
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
        content.sound = startSound.notificationSound
        
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
        content.sound = endSound.notificationSound
        
        let request = UNNotificationRequest(
            identifier: "drive.ended",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        
        center.add(request)
    }

    // MARK: - Sound Preview

    @MainActor
    func preview(sound: NotificationSoundOption) {
        let fileName = (sound.rawValue as NSString).deletingPathExtension
        let fileExtension = (sound.rawValue as NSString).pathExtension
        guard let url = Bundle.main.url(forResource: fileName, withExtension: fileExtension) else {
            return
        }

        do {
            previewPlayer = try AVAudioPlayer(contentsOf: url)
            previewPlayer?.volume = 1.0
            previewPlayer?.prepareToPlay()
            previewPlayer?.play()
        } catch {
            previewPlayer = nil
        }
    }
}
