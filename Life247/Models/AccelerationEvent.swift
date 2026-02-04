//
//  AccelerationEvent.swift
//  Life247
//
//  Created by Andrew Robertson on 1/19/26.
//

import Foundation
import SwiftData
import CoreLocation

/// Type of acceleration event detected during driving
enum AccelerationEventType: String, Codable, CaseIterable {
    case hardBrake = "hardBrake"
    case hardAcceleration = "hardAcceleration"
    case hardCornerLeft = "hardCornerLeft"
    case hardCornerRight = "hardCornerRight"
    
    var displayName: String {
        switch self {
        case .hardBrake: return "Hard Brake"
        case .hardAcceleration: return "Hard Acceleration"
        case .hardCornerLeft: return "Hard Left Turn"
        case .hardCornerRight: return "Hard Right Turn"
        }
    }
    
    /// SF Symbol name for this event type
    var sfSymbol: String {
        switch self {
        case .hardBrake: return "arrow.down.circle.fill"
        case .hardAcceleration: return "arrow.up.circle.fill"
        case .hardCornerLeft: return "arrow.turn.up.left"
        case .hardCornerRight: return "arrow.turn.up.right"
        }
    }
    
    /// CSS/SwiftUI color name for this event type
    var colorName: String {
        switch self {
        case .hardBrake: return "red"
        case .hardAcceleration: return "orange"
        case .hardCornerLeft, .hardCornerRight: return "yellow"
        }
    }
}

/// A significant acceleration event (hard braking, acceleration, or cornering) detected during a drive.
/// Events are stored rather than raw samples to minimize storage while capturing driving behavior.
@Model
final class AccelerationEvent {
    var id: UUID
    var timestamp: Date
    var latitude: Double
    var longitude: Double
    
    /// Event type stored as raw string for SwiftData compatibility
    var eventTypeRaw: String
    
    /// Peak G-force magnitude (always positive)
    var gForceMagnitude: Double
    
    /// Longitudinal G (negative = braking, positive = acceleration)
    var longitudinalG: Double
    
    /// Lateral G (negative = left turn, positive = right turn)
    var lateralG: Double
    
    /// GPS speed at event time (m/s), used for corroboration
    var gpsSpeed: Double
    
    /// GPS speed delta over the event window (m/s), negative = decelerating
    var gpsSpeedDelta: Double?
    
    /// Whether this event was corroborated by GPS speed change
    var gpsCorroborated: Bool
    
    /// Duration of the event in seconds (from threshold entry to exit)
    var durationSeconds: Double?
    
    /// Vehicle heading at time of event (degrees from North)
    var heading: Double
    
    // MARK: - Relationships
    
    var drive: Drive?
    
    // MARK: - Computed Properties
    
    var eventType: AccelerationEventType {
        get { AccelerationEventType(rawValue: eventTypeRaw) ?? .hardBrake }
        set { eventTypeRaw = newValue.rawValue }
    }
    
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    
    /// Formatted G-force for display
    var formattedG: String {
        String(format: "%.2fg", gForceMagnitude)
    }
    
    /// Speed in MPH at event time
    var speedMPH: Double {
        gpsSpeed * 2.23694
    }
    
    // MARK: - Initialization
    
    init(
        timestamp: Date,
        latitude: Double,
        longitude: Double,
        eventType: AccelerationEventType,
        gForceMagnitude: Double,
        longitudinalG: Double,
        lateralG: Double,
        gpsSpeed: Double,
        gpsSpeedDelta: Double? = nil,
        gpsCorroborated: Bool,
        durationSeconds: Double? = nil,
        heading: Double,
        drive: Drive? = nil
    ) {
        self.id = UUID()
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.eventTypeRaw = eventType.rawValue
        self.gForceMagnitude = gForceMagnitude
        self.longitudinalG = longitudinalG
        self.lateralG = lateralG
        self.gpsSpeed = gpsSpeed
        self.gpsSpeedDelta = gpsSpeedDelta
        self.gpsCorroborated = gpsCorroborated
        self.durationSeconds = durationSeconds
        self.heading = heading
        self.drive = drive
    }
}

// MARK: - Upload DTO

/// Codable DTO for uploading acceleration events to the server
struct AccelerationEventUploadDTO: Codable {
    let eventId: String
    let timestamp: String // ISO8601
    let latitude: Double
    let longitude: Double
    let eventType: String
    let gForceMagnitude: Double
    let longitudinalG: Double
    let lateralG: Double
    let gpsSpeed: Double
    let gpsSpeedDelta: Double?
    let gpsCorroborated: Bool
    let durationSeconds: Double?
    let heading: Double
    
    init(from event: AccelerationEvent) {
        self.eventId = event.id.uuidString
        
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.timestamp = formatter.string(from: event.timestamp)
        
        self.latitude = event.latitude
        self.longitude = event.longitude
        self.eventType = event.eventTypeRaw
        self.gForceMagnitude = event.gForceMagnitude
        self.longitudinalG = event.longitudinalG
        self.lateralG = event.lateralG
        self.gpsSpeed = event.gpsSpeed
        self.gpsSpeedDelta = event.gpsSpeedDelta
        self.gpsCorroborated = event.gpsCorroborated
        self.durationSeconds = event.durationSeconds
        self.heading = event.heading
    }
}
