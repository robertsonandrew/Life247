//
//  DriveStartReason.swift
//  Life247
//
//  Created by Andrew Robertson on 1/16/26.
//

import Foundation

/// Reason why a drive was started.
/// Used for debugging and diagnostics in the Drive Inspector.
enum DriveStartReason: String, Codable {
    case user                       // Manual start by user
    case motionActivity             // CMMotionActivity detected automotive
    case gpsSpeed                   // GPS speed exceeded threshold
    case significantLocationChange  // SLC wake triggered detection
    case visitDeparture             // CLVisit departure detected
    case geofenceExit               // Exited a monitored region
    case coldStartRecovery          // App launched and detected in-progress drive
}
