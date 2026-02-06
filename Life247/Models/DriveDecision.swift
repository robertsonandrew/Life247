//
//  DriveDecision.swift
//  Life247
//
//  Created by Andrew Robertson on 1/16/26.
//

import Foundation

/// Records WHY the state machine made a decision.
/// This is the "secret sauce" for debugging drive detection.
/// Stored as metadata in DriveLogEntry for decision category events.
struct DriveDecision: Codable {
    let timestamp: Date
    let rule: String               // e.g. "MotionAutomotiveHighConfidence"
    let outcome: String            // e.g. "transitionToDriving"
    let inputs: [String: String]   // Snapshot of relevant state at decision time
    
    /// Create metadata dictionary for DriveLogEntry
    func asMetadata() -> [String: String] {
        var result: [String: String] = [
            "rule": rule,
            "outcome": outcome,
            "reason_code": rule,
            "decision_outcome": outcome
        ]
        // Flatten inputs with "input_" prefix
        for (key, value) in inputs {
            result["input_\(key)"] = value
        }

        // Canonical aliases for common decision fields.
        if let from = inputs["fromState"] {
            result["state_from"] = from
        }
        if let to = inputs["toState"] {
            result["state_to"] = to
        }
        if let trigger = inputs["trigger"] {
            result["trigger"] = trigger
        }
        return result
    }
    
    /// Human-readable summary for timeline display
    var summary: String {
        "\(outcome) via \(rule)"
    }
}

// MARK: - Common Decision Rules

extension DriveDecision {
    static func driveStarted(
        reason: DriveStartReason,
        speed: Double,
        motionConfidence: String,
        appState: String
    ) -> DriveDecision {
        DriveDecision(
            timestamp: Date(),
            rule: "DriveStart_\(reason.rawValue)",
            outcome: "driveStarted",
            inputs: [
                "startReason": reason.rawValue,
                "speed": String(format: "%.1f m/s", speed),
                "motionConfidence": motionConfidence,
                "appState": appState
            ]
        )
    }
    
    static func driveEnded(
        reason: DriveEndReason,
        stationaryDuration: TimeInterval,
        speed: Double
    ) -> DriveDecision {
        DriveDecision(
            timestamp: Date(),
            rule: "DriveEnd_\(reason.rawValue)",
            outcome: "driveEnded",
            inputs: [
                "endReason": reason.rawValue,
                "stationaryDuration": String(format: "%.0fs", stationaryDuration),
                "speed": String(format: "%.1f m/s", speed)
            ]
        )
    }
    
    static func stateTransition(
        from: String,
        to: String,
        trigger: String,
        inputs: [String: String] = [:]
    ) -> DriveDecision {
        var allInputs = inputs
        allInputs["fromState"] = from
        allInputs["toState"] = to
        allInputs["trigger"] = trigger
        
        return DriveDecision(
            timestamp: Date(),
            rule: "StateTransition",
            outcome: "\(from) → \(to)",
            inputs: allInputs
        )
    }
}
