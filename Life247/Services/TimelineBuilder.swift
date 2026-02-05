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
    static let maxInDriveStopDisplacement: CLLocationDistance = 120
    static let maxInDriveStopEndpointSpeedMPH: Double = 12
    
    /// Build timeline from drives and places.
    /// - Parameters:
    ///   - drives: Completed drives sorted by startTime descending (newest first)
    ///   - places: User-defined places for matching
    ///   - limit: Optional limit on number of drives to process (for pagination performance)
    /// - Returns: Interleaved timeline items (drives and stops)
    static func buildTimeline(
        drives: [Drive],
        places: [Place],
        limit: Int? = nil
    ) async -> [TimelineItem] {
        guard !drives.isEmpty else { return [] }
        
        var items: [TimelineItem] = []
        
        // Apply limit for pagination performance - only process needed drives
        let sortedDrives = limit.map { Array(drives.prefix($0)) } ?? drives
        
        for (index, drive) in sortedDrives.enumerated() {
            // Add the drive (uses cached maxSpeedMPH if available)
            let maxSpeed = drive.maxSpeedMPH
            let destinationName = destinationName(for: drive, places: places)
            items.append(.drive(drive, trace: drive.tracePointsWithSpeed, maxSpeedMPH: maxSpeed, destinationName: destinationName))

            // Infer one stop segment inside this drive from large stationary gaps.
            // Appended after the drive so between-drive stop linking remains stable.
            if let inDriveStop = inferInDriveStop(for: drive, places: places) {
                items.append(.stop(inDriveStop))
            }
            
            // Check for stop between this drive and the next (older) one
            if index < sortedDrives.count - 1 {
                let nextDrive = sortedDrives[index + 1]
                
                if let stop = await inferStop(
                    after: nextDrive,
                    before: drive,
                    places: places
                ) {
                    // We found a stop following 'nextDrive' (which is actually older in sortedDrives). 
                    // Wait, sortedDrives is "newest first".
                    // Drive[0] is most recent. Drive[1] is older.
                    // Stop happens BETWEEN Drive[1] (older) and Drive[0] (newer).
                    // So the stop is the DESTINATION of Drive[1].
                    // My previous logic: "If index < sortedDrives.count - 1".
                    // The inferStop is called with "after: nextDrive (older)" and "before: drive (newer)".
                    // Stop is between nextDrive and drive.
                    // So Stop is the destination of NEXTDRIVE (the older one).
                    // Drive[0] (newest) has NO known destination stop unless we check the ongoing state (which isn't here).
                    
                    // So when we find a stop here, we should update the LAST added drive... which is 'drive' (the NEWER one)? NO.
                    // Let's trace:
                    // Loop index 0: Drive A (Newest). Added to items[0].
                    // Check gap between Drive A and Drive B (Older).
                    // If Stop S exists: It is between B and A.
                    // So B -> S -> A.
                    // So Stop S is the destination of Drive B.
                    // But Drive B hasn't been added yet! It will be added in iteration index 1.
                    
                    // Logic mismatch.
                    // Let's re-read buildTimeline.
                    // "drives: Completed drives sorted by startTime descending (newest first)"
                    // Loop enumerates drives.
                    // Item append order: Newest item first?
                    // "items.append(.drive(drive...))"
                    // If inputs are A, B, C (A=Newest)
                    // Loop 0: Append A. Check gap A-B. Stop S1 found. Stop S1 is start of A, end of B.
                    // Loop 1: Append B. Check gap B-C. Stop S2 found. Stop S2 is start of B, end of C.
                    
                    // So:
                    // Drive B ends at Stop S1.
                    // Drive C ends at Stop S2.
                    // Drive A ends at... unknown (current time/now).
                    
                    // So if I find a stop between A and B, that stop is B's destination.
                    // I haven't added B yet.
                    
                    // Strategy adjustment:
                    // Pass 1: Build basic list with stops.
                    // Pass 2: Iterate and link.
                    // Since the list is reversed (newest first), if `items[i]` is a Stop and `items[i+1]` is a Drive, then `items[i+1].destination = items[i].name`.
                    // (Assuming timeline order matches drive order).
                    
                    items.append(.stop(stop))
                }
            }
        }
        
        // Pass 2: Link drives to their destination stops
        // Timeline is [Drive A, Stop S1, Drive B, Stop S2, Drive C]
        // Stop S1 follows Drive B (in time)? No.
        // Array order is Newest -> Oldest.
        // Time: Drive C -> S2 -> Drive B -> S1 -> Drive A.
        // Array: A, S1, B, S2, C.
        // S1 is the START of A. S1 is the END of B.
        // So B's destination is S1. B is at index i+2 relative to A?
        // Pattern: ... Stop(S), Drive(D) ...
        // Since list is Newest -> Oldest:
        // S comes BEFORE D in the list? No, S happens BEFORE A.
        // Wait, timeline build order:
        // inferStop(after: nextDrive (older/B), before: drive (newer/A))
        // Returns stop S. S.startTime = B.endTime. S.endTime = A.startTime.
        // So S is Chronologically AFTER B.
        // So S is B's destination.
        // In the list `items`, we appended A, then appended S.
        // Next loop, we append B.
        // So list is [A, S, B, ...].
        // So if we see [Stop, Drive], that Stop is the destination of that Drive.
        
        // Let's implement Pass 2.
        
        var linkedItems = items
        for i in 0..<linkedItems.count - 1 {
            if case .stop(let stop) = linkedItems[i],
               case .drive(let drive, let trace, let maxSpeed, let existingName) = linkedItems[i+1] {
                   guard stop.source == .betweenDrives else { continue }
                   // Found a Stop followed by a Drive (in array order, meaning Drive -> Stop in time)
                   // Verify? Array index 0 is newest. Index 10 is oldest.
                   // i (Stop S) is newer than i+1 (Drive D).
                   // Logic: D -> S.
                   // So D is older than S.
                   // Correct. D's destination is S.
                   if let placeName = stop.matchedPlace?.name {
                       linkedItems[i+1] = .drive(drive, trace: trace, maxSpeedMPH: maxSpeed, destinationName: placeName)
                   } else {
                       linkedItems[i+1] = .drive(drive, trace: trace, maxSpeedMPH: maxSpeed, destinationName: existingName)
                   }
            }
        }
        
        return linkedItems
    }

    /// Infer a stop segment inside a single drive from a long stationary GPS gap.
    /// Uses the longest candidate gap where endpoints are near each other and low speed.
    private static func inferInDriveStop(
        for drive: Drive,
        places: [Place]
    ) -> InferredStop? {
        let points = drive.pointsChronological
        guard points.count >= 2 else { return nil }

        var bestCandidate: (start: Date, end: Date, location: CLLocationCoordinate2D, gap: TimeInterval)?

        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let gap = current.timestamp.timeIntervalSince(previous.timestamp)
            guard gap >= minimumStopDuration else { continue }

            let previousLocation = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
            let currentLocation = CLLocation(latitude: current.latitude, longitude: current.longitude)
            let displacement = previousLocation.distance(from: currentLocation)
            guard displacement <= maxInDriveStopDisplacement else { continue }

            guard previous.speedMPH <= maxInDriveStopEndpointSpeedMPH,
                  current.speedMPH <= maxInDriveStopEndpointSpeedMPH else { continue }

            if bestCandidate == nil || gap > bestCandidate!.gap {
                bestCandidate = (previous.timestamp, current.timestamp, previous.coordinate, gap)
            }
        }

        guard let candidate = bestCandidate else { return nil }
        let matchedPlace = findNearestContainingPlace(for: candidate.location, in: places)

        return InferredStop(
            id: UUID(),
            location: candidate.location,
            startTime: candidate.start,
            endTime: candidate.end,
            matchedPlace: matchedPlace,
            address: nil,
            source: .inDriveGap
        )
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
        
        // Stop location = end snapshot (fallbacks to last point)
        guard let stopLocation = previousDrive.endCoordinateSnapshot else { return nil }

        // Match to saved place (prefer explicit endPlaceId if set)
        var matchedPlace: Place?
        if let endPlaceId = previousDrive.endPlaceId {
            matchedPlace = places.first { $0.placeId == endPlaceId }
        }
        if matchedPlace == nil {
            matchedPlace = findNearestContainingPlace(
                for: stopLocation,
                in: places
            )
        }
        
        // NOTE: Address geocoding is now lazy - handled by StopRowView
        // This prevents N serial geocoding calls from blocking timeline build
        
        return InferredStop(
            id: UUID(),
            location: stopLocation,
            startTime: previousEndTime,
            endTime: nextDrive.startTime,
            matchedPlace: matchedPlace,
            address: nil,  // Lazy loaded by view
            source: .betweenDrives
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

    /// Determine a destination name directly from a drive (used when no inferred stop exists).
    private static func destinationName(for drive: Drive, places: [Place]) -> String? {
        if let endPlaceId = drive.endPlaceId,
           let place = places.first(where: { $0.placeId == endPlaceId }) {
            return place.name
        }
        if let coord = drive.endCoordinateSnapshot,
           let place = findNearestContainingPlace(for: coord, in: places) {
            return place.name
        }
        return nil
    }
}
