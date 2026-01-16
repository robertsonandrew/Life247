//
//  Drive.swift
//  Life247
//
//  Created by Andrew Robertson on 1/14/26.
//

import Foundation
import SwiftData
import CoreLocation
import MapKit

/// A recorded driving trip.
/// - Created ONLY on `driving` state entry
/// - Finalized ONLY on `ended` state entry
/// - Points appended ONLY while in `driving` state
@Model
final class Drive {
    var id: UUID
    var startTime: Date
    var endTime: Date?
    var distanceMeters: Double
    
    @Relationship(deleteRule: .cascade)
    var points: [LocationPoint]
    
    init(
        id: UUID = UUID(),
        startTime: Date = Date(),
        endTime: Date? = nil,
        distanceMeters: Double = 0,
        points: [LocationPoint] = []
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.distanceMeters = distanceMeters
        self.points = points
    }
    
    // MARK: - Computed Properties
    
    /// Duration of the drive
    var duration: TimeInterval {
        (endTime ?? Date()).timeIntervalSince(startTime)
    }
    
    /// Duration formatted as HH:MM:SS
    var formattedDuration: String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
    
    /// Distance in miles
    var distanceMiles: Double {
        distanceMeters / 1609.344
    }
    
    /// Formatted distance string
    var formattedDistance: String {
        String(format: "%.1f mi", distanceMiles)
    }
    
    /// Average speed in MPH (based on distance and duration)
    var averageSpeedMPH: Double {
        guard duration > 0 else { return 0 }
        return distanceMiles / (duration / 3600)
    }
    
    /// Maximum speed recorded in MPH
    var maxSpeedMPH: Double {
        points.map { $0.speedMPH }.max() ?? 0
    }
    
    /// Start coordinate for map display
    var startCoordinate: CLLocationCoordinate2D? {
        points.first?.coordinate
    }
    
    /// End coordinate for map display
    var endCoordinate: CLLocationCoordinate2D? {
        points.last?.coordinate
    }
    
    /// Short identifier for debugging (first 4 chars of UUID)
    var shortId: String {
        String(id.uuidString.prefix(4))
    }
    
    /// Whether this drive is still in progress
    var isActive: Bool {
        endTime == nil
    }
    
    /// Points in chronological order (SwiftData relationships don't preserve insertion order)
    /// Uses latitude as tie-breaker for stable ordering when timestamps are equal
    var pointsChronological: [LocationPoint] {
        points.sorted {
            if $0.timestamp == $1.timestamp {
                return $0.latitude < $1.latitude
            }
            return $0.timestamp < $1.timestamp
        }
    }
    
    /// Precomputed route bounds for efficient camera fitting
    var routeBounds: (center: CLLocationCoordinate2D, span: MKCoordinateSpan)? {
        let coords = pointsChronological.map { $0.coordinate }
        guard coords.count > 1 else { return nil }
        
        let lats = coords.map { $0.latitude }
        let lons = coords.map { $0.longitude }
        
        guard let minLat = lats.min(),
              let maxLat = lats.max(),
              let minLon = lons.min(),
              let maxLon = lons.max() else { return nil }
        
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: (maxLat - minLat) * 1.3 + 0.005,
            longitudeDelta: (maxLon - minLon) * 1.3 + 0.005
        )
        return (center, span)
    }
    
    /// Sampled points for mini maps (1 point per ~50 meters equivalent)
    /// Reduces point count for performance in list views
    func sampledPoints(maxCount: Int = 100) -> [LocationPoint] {
        let chronological = pointsChronological
        guard chronological.count > maxCount else { return chronological }
        
        let stride = chronological.count / maxCount
        return chronological.enumerated()
            .filter { $0.offset % stride == 0 || $0.offset == chronological.count - 1 }
            .map { $0.element }
    }
    
    // MARK: - Methods
    
    /// Minimum horizontal accuracy to accept a point (meters)
    private static let maxAccuracy: Double = 30.0
    
    /// Maximum reasonable speed to filter GPS spikes (meters/second) - ~150 mph
    private static let maxReasonableSpeed: Double = 67.0
    
    /// Maximum distance jump between consecutive points (meters) - helps filter teleports
    private static let maxDistanceJump: Double = 500.0
    
    /// Add a location point if it passes quality filters
    /// Returns true if point was added, false if rejected
    @discardableResult
    func addPoint(_ location: CLLocation) -> Bool {
        // Filter 1: Reject poor accuracy readings
        guard location.horizontalAccuracy > 0 && location.horizontalAccuracy <= Self.maxAccuracy else {
            return false
        }
        
        // Filter 2: Reject invalid speed readings (negative means invalid)
        guard location.speed >= 0 else {
            return false
        }
        
        // Filter 3: Reject impossibly high speeds (GPS spike)
        guard location.speed <= Self.maxReasonableSpeed else {
            return false
        }
        
        // Filter 4: If we have previous points, check for impossible jumps
        if let lastPoint = points.last {
            let lastLocation = CLLocation(
                latitude: lastPoint.latitude,
                longitude: lastPoint.longitude
            )
            let distance = location.distance(from: lastLocation)
            let timeDelta = location.timestamp.timeIntervalSince(lastPoint.timestamp)
            
            // Reject if time went backwards or is stale
            guard timeDelta > 0 else {
                return false
            }
            
            // Reject teleportation (jumped too far too fast)
            if distance > Self.maxDistanceJump {
                // Check if implied speed is reasonable
                let impliedSpeed = distance / timeDelta
                if impliedSpeed > Self.maxReasonableSpeed {
                    return false
                }
            }
            
            // Update distance (only for reasonable deltas)
            if distance < Self.maxDistanceJump {
                distanceMeters += distance
            }
        }
        
        // Point passed all filters - add it
        let newPoint = LocationPoint(from: location)
        points.append(newPoint)
        return true
    }
    
    /// Finalize the drive with an end time
    func finalize() {
        endTime = Date()
    }
}
