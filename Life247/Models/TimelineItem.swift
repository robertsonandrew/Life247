//
//  TimelineItem.swift
//  Life247
//
//  Created by Andrew Robertson on 1/15/26.
//

import Foundation
import CoreLocation

/// A unified timeline entry - either a drive or an inferred stop.
enum TimelineItem: Identifiable {
    case drive(Drive)
    case stop(InferredStop)
    
    var id: String {
        switch self {
        case .drive(let drive):
            return "drive-\(drive.id.uuidString)"
        case .stop(let stop):
            return "stop-\(stop.id.uuidString)"
        }
    }
    
    /// Start time for sorting (avoids type checking in sort)
    var startTime: Date {
        switch self {
        case .drive(let drive):
            return drive.startTime
        case .stop(let stop):
            return stop.startTime
        }
    }
    
    /// End time for timeline display
    var endTime: Date {
        switch self {
        case .drive(let drive):
            return drive.endTime ?? drive.startTime
        case .stop(let stop):
            return stop.endTime
        }
    }
}

/// An inferred stop between two drives.
/// Ephemeral - computed at runtime, not persisted.
struct InferredStop: Identifiable {
    let id: UUID
    let location: CLLocationCoordinate2D
    let startTime: Date       // Previous drive's endTime
    let endTime: Date         // Next drive's startTime
    let matchedPlace: Place?  // If within a Place's radius
    let address: String?      // Fallback from geocoding
    
    /// Duration of the stop
    var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }
    
    /// Formatted duration (e.g., "8 min")
    var formattedDuration: String {
        let minutes = Int(duration / 60)
        if minutes < 60 {
            return "\(minutes) min"
        } else {
            let hours = minutes / 60
            let remainingMinutes = minutes % 60
            if remainingMinutes == 0 {
                return "\(hours) hr"
            } else {
                return "\(hours) hr \(remainingMinutes) min"
            }
        }
    }
    
    /// Time range string (e.g., "15:21 – 15:29")
    var timeRangeString: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return "\(formatter.string(from: startTime)) – \(formatter.string(from: endTime))"
    }
    
    /// Display name: place name if matched, otherwise address
    var displayName: String {
        matchedPlace?.name ?? address ?? "Stopped"
    }
    
    /// Display icon: place icon if matched, otherwise pin
    var displayIcon: String {
        matchedPlace?.icon ?? "mappin.circle.fill"
    }
}
