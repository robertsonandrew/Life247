//
//  TimelineBuilder.swift
//  Life247
//
//  Created by Andrew Robertson on 1/15/26.
//

import Foundation
import CoreLocation

/// Builds a unified timeline from drives and places.
/// Pure, deterministic, no persistence.
struct TimelineBuilder {
    
    /// Minimum gap duration to consider as a stop (2 minutes)
    static let minimumStopDuration: TimeInterval = 120
    
    /// Build timeline from drives and places.
    /// - Parameters:
    ///   - drives: Completed drives sorted by startTime descending (newest first)
    ///   - places: User-defined places for matching
    /// - Returns: Interleaved timeline items (drives and stops)
    static func buildTimeline(
        drives: [Drive],
        places: [Place]
    ) async -> [TimelineItem] {
        guard !drives.isEmpty else { return [] }
        
        var items: [TimelineItem] = []
        
        // Drives are already sorted newest first
        let sortedDrives = drives
        
        for (index, drive) in sortedDrives.enumerated() {
            // Add the drive
            items.append(.drive(drive))
            
            // Check for stop between this drive and the next (older) one
            if index < sortedDrives.count - 1 {
                let nextDrive = sortedDrives[index + 1]
                
                if let stop = await inferStop(
                    after: nextDrive,
                    before: drive,
                    places: places
                ) {
                    items.append(.stop(stop))
                }
            }
        }
        
        return items
    }
    
    /// Infer a stop between two consecutive drives.
    /// - Parameters:
    ///   - previousDrive: The earlier drive (provides stop location)
    ///   - nextDrive: The later drive
    ///   - places: Places to match against
    /// - Returns: InferredStop if gap is significant, nil otherwise
    private static func inferStop(
        after previousDrive: Drive,
        before nextDrive: Drive,
        places: [Place]
    ) async -> InferredStop? {
        // Must have valid end time on previous drive
        guard let previousEndTime = previousDrive.endTime else { return nil }
        
        // Calculate gap
        let gap = nextDrive.startTime.timeIntervalSince(previousEndTime)
        
        // Ignore short gaps (< 2 minutes)
        guard gap >= minimumStopDuration else { return nil }
        
        // Stop location = last point of previous drive
        guard let lastPoint = previousDrive.points.last else { return nil }
        let stopLocation = lastPoint.coordinate
        
        // Match to nearest place
        let matchedPlace = findNearestContainingPlace(
            for: stopLocation,
            in: places
        )
        
        // Geocode address if no place match
        var address: String? = nil
        if matchedPlace == nil {
            address = await GeocodingCache.shared.address(for: stopLocation)
        }
        
        return InferredStop(
            id: UUID(),
            location: stopLocation,
            startTime: previousEndTime,
            endTime: nextDrive.startTime,
            matchedPlace: matchedPlace,
            address: address
        )
    }
    
    /// Find the nearest place that contains the given coordinate.
    private static func findNearestContainingPlace(
        for coordinate: CLLocationCoordinate2D,
        in places: [Place]
    ) -> Place? {
        let containingPlaces = places.filter { $0.contains(coordinate) }
        
        // Return nearest if multiple overlap
        return containingPlaces.min { a, b in
            a.distance(to: coordinate) < b.distance(to: coordinate)
        }
    }
}
