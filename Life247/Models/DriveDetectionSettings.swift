//
//  DriveDetectionSettings.swift
//  Life247
//
//  Created by Andrew Robertson on 1/14/26.
//

import Foundation
import SwiftUI

/// User-adjustable drive detection parameters.
/// Lightweight struct using @AppStorage - read lazily, never cached.
struct DriveDetectionSettings {
    
    // MARK: - Stored Settings
    
    /// Duration at low speed before entering stopped state (seconds)
    /// Range: 10-120s, Default: 30s
    @AppStorage("stoppedDetectionDuration") var stoppedDetectionDuration: Double = 30.0
    
    /// How long stopped before auto-ending drive (minutes)
    /// Range: 1-15 min, Default: 5 min
    @AppStorage("stoppedTimeoutMinutes") var stoppedTimeoutMinutes: Int = 5
    
    /// Duration to maintain speed before confirming drive (seconds)
    /// Range: 5-30s, Default: 10s
    @AppStorage("drivingConfirmationDuration") var drivingConfirmationDuration: Double = 10.0
    
    // MARK: - Defaults
    
    static let defaultStoppedDetectionDuration: Double = 30.0
    static let defaultStoppedTimeoutMinutes: Int = 5
    static let defaultDrivingConfirmationDuration: Double = 10.0
    
    // MARK: - Ranges
    
    static let stoppedDetectionRange: ClosedRange<Double> = 10...120
    static let stoppedTimeoutRange: ClosedRange<Int> = 1...15
    static let drivingConfirmationRange: ClosedRange<Double> = 5...30
    
    // MARK: - Reset
    
    /// Resets all settings to default values.
    /// Writes defaults to AppStorage, triggering UI refresh automatically.
    mutating func resetToDefaults() {
        stoppedDetectionDuration = Self.defaultStoppedDetectionDuration
        stoppedTimeoutMinutes = Self.defaultStoppedTimeoutMinutes
        drivingConfirmationDuration = Self.defaultDrivingConfirmationDuration
    }
}
