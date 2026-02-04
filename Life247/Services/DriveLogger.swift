//
//  DriveLogger.swift
//  Life247
//
//  Created by Andrew Robertson on 1/16/26.
//

import Foundation
import SwiftData
import UIKit

/// Lightweight service that appends log entries to the active drive.
/// This is the "flight recorder" that captures events for the Drive Inspector.
@MainActor
final class DriveLogger {
    
    private weak var activeDrive: Drive?
    private var modelContext: ModelContext?
    
    // MARK: - Lifecycle
    
    /// Attach the logger to a drive and model context
    func attach(to drive: Drive, context: ModelContext) {
        self.activeDrive = drive
        self.modelContext = context
        
        log(.system, type: "logger_attached", message: "DriveLogger attached to drive \(drive.shortId)")
    }
    
    /// Detach from the current drive
    func detach() {
        if let drive = activeDrive {
            log(.system, type: "logger_detached", message: "DriveLogger detached from drive \(drive.shortId)")
        }
        self.activeDrive = nil
        self.modelContext = nil
    }
    
    // MARK: - Logging
    
    /// Log a general event
    func log(
        _ category: LogCategory,
        type: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        guard let drive = activeDrive else { return }
        
        let entry = DriveLogEntry(
            category: category,
            eventType: type,
            message: message,
            metadata: metadata.isEmpty ? nil : metadata
        )
        entry.drive = drive
        // Make persistence explicit. Relying solely on relationship insertion can be brittle,
        // especially during background execution.
        if let modelContext {
            modelContext.insert(entry)
        }
        drive.logEntries.append(entry)
    }
    
    /// Log a state machine decision with full context
    func logDecision(_ decision: DriveDecision) {
        log(
            .decision,
            type: decision.rule,
            message: decision.summary,
            metadata: decision.asMetadata()
        )
    }
    
    /// Log an anomaly (error or unexpected behavior)
    func logAnomaly(
        _ type: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        log(.anomaly, type: type, message: message, metadata: metadata)
    }
    
    // MARK: - Convenience Logging Methods
    
    /// Log app state change (foreground/background)
    func logAppStateChange(to state: String) {
        log(.system, type: "app_state_changed", message: "App \(state)", metadata: ["state": state])
    }
    
    /// Log motion activity change
    func logMotionActivity(
        automotive: Bool,
        confidence: String,
        walking: Bool = false,
        stationary: Bool = false
    ) {
        let activity: String
        if automotive {
            activity = "automotive"
        } else if walking {
            activity = "walking"
        } else if stationary {
            activity = "stationary"
        } else {
            activity = "unknown"
        }
        
        log(
            .motion,
            type: "motion_activity",
            message: "Motion: \(activity) (\(confidence))",
            metadata: [
                "automotive": String(automotive),
                "confidence": confidence,
                "walking": String(walking),
                "stationary": String(stationary)
            ]
        )
    }
    
    /// Log location update with accuracy
    func logLocationUpdate(
        accuracy: Double,
        speed: Double,
        isFirstFix: Bool = false
    ) {
        let type = isFirstFix ? "first_location_fix" : "location_update"
        let message = isFirstFix
            ? "First GPS fix (accuracy: \(Int(accuracy))m)"
            : "Location update (accuracy: \(Int(accuracy))m, speed: \(String(format: "%.1f", speed * 2.237)) mph)"
        
        log(
            .location,
            type: type,
            message: message,
            metadata: [
                "accuracy": String(format: "%.1f", accuracy),
                "speed": String(format: "%.2f", speed),
                "isFirstFix": String(isFirstFix)
            ]
        )
    }
    
    /// Log location services pause/resume
    func logLocationServicesPaused(_ paused: Bool) {
        let type = paused ? "location_paused" : "location_resumed"
        let message = paused ? "Location updates paused by system" : "Location updates resumed"
        log(.system, type: type, message: message)
        
        // Update pause count on drive
        if paused {
            activeDrive?.locationPauseCount += 1
        }
    }
    
    /// Log a GPS gap detected between samples
    func logGPSGap(gapDuration: TimeInterval) {
        logAnomaly(
            "gps_gap",
            message: "GPS gap detected: \(String(format: "%.0f", gapDuration))s",
            metadata: ["gapSeconds": String(format: "%.1f", gapDuration)]
        )
        
        // Update max gap if this is longer
        if let drive = activeDrive, gapDuration > drive.maxGapBetweenSamples {
            drive.maxGapBetweenSamples = gapDuration
        }
    }
    
    /// Log battery level change
    func logBatteryLevel(_ level: Float, isCharging: Bool) {
        log(
            .system,
            type: "battery_update",
            message: "Battery: \(Int(level * 100))%\(isCharging ? " (charging)" : "")",
            metadata: [
                "level": String(format: "%.2f", level),
                "isCharging": String(isCharging)
            ]
        )
    }
    
    /// Log state transition
    func logStateTransition(from: String, to: String, trigger: String, metadata: [String: String] = [:]) {
        var meta = metadata
        meta["fromState"] = from
        meta["toState"] = to
        meta["trigger"] = trigger
        log(
            .decision,
            type: "state_transition",
            message: "\(from) → \(to)",
            metadata: meta
        )
    }

    /// Log verbose trace (optional)
    func logTrace(type: String, message: String, metadata: [String: String] = [:]) {
        log(.trace, type: type, message: message, metadata: metadata)
    }
}
