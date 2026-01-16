//
//  MapCameraPolicy.swift
//  Life247
//
//  Created by Andrew Robertson on 1/15/26.
//

import Foundation
import SwiftUI
import MapKit
import CoreLocation

// MARK: - Tracking Mode

/// Camera behavior policies for the map view.
enum MapTrackingMode {
    case free              // User panned away, no auto-follow
    case follow            // North-up, flat, centered on user
    case followWithHeading // Heading-up, flat, centered on user
    case drivingView       // Heading-up, 3D pitch, look-ahead
}

// MARK: - Camera Policy

/// Returns the appropriate MapCamera for the given tracking mode and location.
/// Camera math is isolated here for testability and clarity.
func mapCamera(
    for mode: MapTrackingMode,
    location: CLLocation,
    speed: CLLocationSpeed,
    zoomLevel: MapZoomLevel = .neighborhood
) -> MapCamera {
    let speedMPH = max(0, speed * 2.23694)
    let course = location.course >= 0 ? location.course : 0
    
    switch mode {
    case .free:
        // No camera update when in free mode
        // Return current position as fallback
        return MapCamera(
            centerCoordinate: location.coordinate,
            distance: zoomLevel.distance,
            heading: 0,
            pitch: 0
        )
        
    case .follow:
        return MapCamera(
            centerCoordinate: location.coordinate,
            distance: zoomLevel.distance,
            heading: 0,
            pitch: 0
        )
        
    case .followWithHeading:
        return MapCamera(
            centerCoordinate: location.coordinate,
            distance: zoomLevel.distance,
            heading: course,
            pitch: 0
        )
        
    case .drivingView:
        // Look-ahead: project center 120m forward
        let centerAhead = location.coordinate.projected(
            distance: 120,
            bearing: course
        )
        
        // Pitch disabled at low speeds to avoid jitter
        let pitch: Double = speedMPH >= 5 ? 60 : 0
        
        return MapCamera(
            centerCoordinate: centerAhead,
            distance: zoomLevel.drivingDistance,
            heading: course,
            pitch: pitch
        )
    }
}

// MARK: - Coordinate Projection

extension CLLocationCoordinate2D {
    /// Projects a coordinate forward by a distance (meters) along a bearing (degrees).
    /// Uses great-circle (haversine) math for accuracy.
    func projected(distance: Double, bearing: Double) -> CLLocationCoordinate2D {
        let earthRadius = 6371000.0 // meters
        
        let lat1 = latitude * .pi / 180
        let lon1 = longitude * .pi / 180
        let bearingRad = bearing * .pi / 180
        let angularDistance = distance / earthRadius
        
        let lat2 = asin(
            sin(lat1) * cos(angularDistance) +
            cos(lat1) * sin(angularDistance) * cos(bearingRad)
        )
        
        let lon2 = lon1 + atan2(
            sin(bearingRad) * sin(angularDistance) * cos(lat1),
            cos(angularDistance) - sin(lat1) * sin(lat2)
        )
        
        return CLLocationCoordinate2D(
            latitude: lat2 * 180 / .pi,
            longitude: lon2 * 180 / .pi
        )
    }
}
