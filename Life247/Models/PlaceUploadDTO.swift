//
//  PlaceUploadDTO.swift
//  Life247
//
//  Created by Andrew Robertson on 1/22/26.
//

import Foundation

/// Data Transfer Object for uploading Places to the sync server
struct PlaceUploadDTO: Codable {
    let placeId: String
    let deviceId: String
    let name: String
    let latitude: Double
    let longitude: Double
    let radiusMeters: Double
    let icon: String
    
    init(from place: Place, deviceId: String) {
        self.placeId = place.placeId.uuidString
        self.deviceId = deviceId
        self.name = place.name
        self.latitude = place.latitude
        self.longitude = place.longitude
        self.radiusMeters = place.radiusMeters
        self.icon = place.icon
    }
}
