//
//  MapZoomLevel.swift
//  Life247
//
//  Created by Andrew Robertson on 1/15/26.
//

import Foundation

/// Default zoom level presets for the map.
enum MapZoomLevel: String, CaseIterable, Identifiable {
    case street = "street"
    case neighborhood = "neighborhood"
    case city = "city"
    case region = "region"
    
    var id: String { rawValue }
    
    var label: String {
        switch self {
        case .street: return "Street"
        case .neighborhood: return "Neighborhood"
        case .city: return "City"
        case .region: return "Region"
        }
    }
    
    var description: String {
        switch self {
        case .street: return "Close up, see buildings"
        case .neighborhood: return "Few blocks visible"
        case .city: return "Overview of area"
        case .region: return "Wide view, highways visible"
        }
    }
    
    /// Camera distance in meters
    var distance: Double {
        switch self {
        case .street: return 300
        case .neighborhood: return 600
        case .city: return 1500
        case .region: return 5000
        }
    }
    
    /// Zoom multiplier for driving view (tighter zoom when moving)
    var drivingDistance: Double {
        switch self {
        case .street: return 400
        case .neighborhood: return 800
        case .city: return 1200
        case .region: return 3000
        }
    }
}
