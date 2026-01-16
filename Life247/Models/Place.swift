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
    var name: String
    var latitude: Double
    var longitude: Double
    var radiusMeters: Double
    var icon: String
    
    init(
        name: String,
        latitude: Double,
        longitude: Double,
        radiusMeters: Double = 100,
        icon: String = "mappin.circle.fill"
    ) {
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
    
    // MARK: - Containment Check (Pure, no side effects)
    
    /// Returns true if the given coordinate is within this place's radius.
    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        let center = CLLocation(latitude: latitude, longitude: longitude)
        let point = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return center.distance(from: point) <= radiusMeters
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
