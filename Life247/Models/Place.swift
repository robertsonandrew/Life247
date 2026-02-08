//
//  Place.swift
//  Life247
//
//  Created by Andrew Robertson on 1/15/26.
//

import Foundation
import SwiftData
import CoreLocation

/// A user-defined named location with geofence radius.
/// Used for matching stops to meaningful places (Home, Work, Gym, etc.)
@Model
final class Place {
    static let minUserRadiusMeters: Double = 20
    static let maxUserRadiusMeters: Double = 500

    /// Unique identifier for geofence registration (stable across app launches)
    /// Default value allows migration from existing Places without this property
    var placeId: UUID = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    var radiusMeters: Double
    var icon: String
    
    init(
        placeId: UUID = UUID(),
        name: String,
        latitude: Double,
        longitude: Double,
        radiusMeters: Double = 100,
        icon: String = "mappin.circle.fill"
    ) {
        self.placeId = placeId
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
        self.icon = icon
    }
    
    /// Convenience initializer from CLLocationCoordinate2D
    convenience init(
        name: String,
        coordinate: CLLocationCoordinate2D,
        radiusMeters: Double = 100,
        icon: String = "mappin.circle.fill"
    ) {
        self.init(
            placeId: UUID(),
            name: name,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            radiusMeters: radiusMeters,
            icon: icon
        )
    }
    
    // MARK: - Computed Properties
    
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    
    // MARK: - Effective Radius

    /// Radius constrained to the UI-editable range.
    /// This protects rendering/geofencing from legacy outlier values.
    var clampedRadiusMeters: Double {
        min(Self.maxUserRadiusMeters, max(Self.minUserRadiusMeters, radiusMeters))
    }

    /// Radius used for in-app containment decisions (dwell matching, map display).
    /// This tracks what the user configured in the editor (after clamping to UI bounds).
    ///
    /// Note: Geofence monitoring radius is computed separately at registration time and may be larger.
    var effectiveRadius: Double {
        clampedRadiusMeters
    }
    
    // MARK: - Containment Check (Pure, no side effects)
    
    /// Returns true if the given coordinate is within this place's effective radius.
    /// - Parameter additionalBufferMeters: Optional buffer (for GPS uncertainty handling).
    func contains(_ coordinate: CLLocationCoordinate2D, additionalBufferMeters: CLLocationDistance = 0) -> Bool {
        let center = CLLocation(latitude: latitude, longitude: longitude)
        let point = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let bufferedRadius = effectiveRadius + max(0, additionalBufferMeters)
        return center.distance(from: point) <= bufferedRadius
    }
    
    /// Distance from this place to a given coordinate.
    func distance(to coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
        let center = CLLocation(latitude: latitude, longitude: longitude)
        let point = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return center.distance(from: point)
    }
}

// MARK: - Common Place Icons

extension Place {
    static let commonIcons: [(name: String, icon: String)] = [
        ("Home", "house.fill"),
        ("Work", "building.2.fill"),
        ("Gym", "figure.run"),
        ("School", "graduationcap.fill"),
        ("Store", "cart.fill"),
        ("Restaurant", "fork.knife"),
        ("Gas Station", "fuelpump.fill"),
        ("Hospital", "cross.fill"),
        ("Park", "leaf.fill"),
        ("Other", "mappin.circle.fill")
    ]
}
