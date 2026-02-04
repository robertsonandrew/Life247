//
//  MapZoomLevel.swift
//  Life247
//
//  Created by Andrew Robertson on 1/15/26.
//

import Foundation

/// Default zoom level presets for the map.
/// Aligned with industry standards (Apple Maps / Google Maps approximate zoom levels).
enum MapZoomLevel: String, CaseIterable, Identifiable {
    case building = "building"
    case street = "street"
    case area = "area"
    case town = "town"
    case metro = "metro"
    
    var id: String { rawValue }
    
    var label: String {
        switch self {
        case .building: return "Building"
        case .street: return "Street"
        case .area: return "Area"
        case .town: return "Town"
        case .metro: return "Metro"
        }
    }
    
    var description: String {
        switch self {
        case .building: return "Buildings & parked cars"
        case .street: return "City block, intersections"
        case .area: return "Multiple blocks, parks"
        case .town: return "Major roads, landmarks"
        case .metro: return "City overview, highways"
        }
    }
    
    /// Camera distance in meters (follow mode - flat, north-up)
    /// Based on industry-standard map zoom levels
    var distance: Double {
        switch self {
        case .building: return 200       // ~zoom 18
        case .street: return 500         // ~zoom 16
        case .area: return 2_000         // ~zoom 14
        case .town: return 6_000         // ~zoom 12
        case .metro: return 20_000       // ~zoom 10
        }
    }
    
    /// Camera distance for driving view (tighter than follow for better road context)
    var drivingDistance: Double {
        switch self {
        case .building: return 250
        case .street: return 500
        case .area: return 1_200
        case .town: return 3_500
        case .metro: return 10_000
        }
    }
}
