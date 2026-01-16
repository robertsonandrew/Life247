//
//  LocationPoint.swift
//  Life247
//
//  Created by Andrew Robertson on 1/14/26.
//

import Foundation
import SwiftData
import CoreLocation

/// A GPS point recorded during a drive.
/// Points are only appended while in the `driving` state.
@Model
final class LocationPoint {
    var timestamp: Date
    var latitude: Double
    var longitude: Double
    var speed: Double              // meters per second
    var altitude: Double           // meters
    var horizontalAccuracy: Double // meters
    var course: Double             // degrees, -1 if invalid
    
    init(
        timestamp: Date,
        latitude: Double,
        longitude: Double,
        speed: Double,
        altitude: Double,
        horizontalAccuracy: Double,
        course: Double = -1
    ) {
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.speed = speed
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.course = course
    }
    
    /// Convenience initializer from CLLocation
    convenience init(from location: CLLocation) {
        self.init(
            timestamp: location.timestamp,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            speed: max(0, location.speed), // -1 means invalid
            altitude: location.altitude,
            horizontalAccuracy: location.horizontalAccuracy,
            course: location.course
        )
    }
    
    /// Speed in miles per hour
    var speedMPH: Double {
        speed * 2.23694
    }
    
    /// CLLocationCoordinate2D for MapKit
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
