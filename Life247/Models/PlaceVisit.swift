//
//  PlaceVisit.swift
//  Life247
//
//  Created by Andrew Robertson on 1/18/26.
//

import Foundation
import SwiftData
import CoreLocation

/// A dwell session at/near a saved Place.
///
/// Persisted so it can be synced to the server and used for analytics.
/// Created/ended by `DriveStateMachine` (single source of truth).
@Model
final class PlaceVisit {
    var id: UUID

    // Visit timing
    var arrivalTime: Date
    var departureTime: Date?

    // Visit location (from CLVisit)
    var latitude: Double
    var longitude: Double

    // Link to current Place (nullable if deleted)
    @Relationship(deleteRule: .nullify)
    var place: Place?

    // Snapshot fields (stable for analytics/sync even if Place changes)
    var placeName: String
    var placeIcon: String
    var placeRadiusMeters: Double
    var placeLatitude: Double
    var placeLongitude: Double

    // Source ("clvisit")
    var source: String

    // Sync status
    var syncedAt: Date?
    var syncStatus: String? // "pending", "synced", "failed"

    init(
        id: UUID = UUID(),
        arrivalTime: Date,
        departureTime: Date? = nil,
        coordinate: CLLocationCoordinate2D,
        place: Place,
        source: String = "clvisit"
    ) {
        self.id = id
        self.arrivalTime = arrivalTime
        self.departureTime = departureTime
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude

        self.place = place
        self.placeName = place.name
        self.placeIcon = place.icon
        self.placeRadiusMeters = place.radiusMeters
        self.placeLatitude = place.latitude
        self.placeLongitude = place.longitude

        self.source = source
        self.syncStatus = "pending"
    }

    // MARK: - Computed

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var isActive: Bool {
        departureTime == nil
    }

    var duration: TimeInterval {
        (departureTime ?? Date()).timeIntervalSince(arrivalTime)
    }

    var formattedDuration: String {
        let seconds = Int(duration)
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}
