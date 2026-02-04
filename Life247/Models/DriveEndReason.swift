//
//  DriveEndReason.swift
//  Life247
//
//  Created by Andrew Robertson on 1/16/26.
//

import Foundation

/// Reason why a drive was ended.
/// Used for debugging and diagnostics in the Drive Inspector.
enum DriveEndReason: String, Codable {
    case user                   // Manual end by user
    case inactivityTimeout      // No movement for threshold duration
    case appTermination         // App was terminated by system/user
    case systemSuspension       // iOS suspended the app
    case lowBattery             // Battery critically low
    case visitArrival           // CLVisit arrival detected
    case stuckRecovery          // Recovered from stuck state
    case geofenceEntry          // Arrived at a saved place (geofence)
    case geofenceEntryLowSpeed  // Entered geofence at low speed (high confidence arrival)
    case walkingDetected        // User started walking while stopped
    case safetyTimeout          // Safety timer expired (max drive duration)
}
