//
//  DriveUploadDTO.swift
//  Life247
//
//  Created by Andrew Robertson on 1/17/26.
//

import Foundation
import UIKit

/// Codable DTO for uploading drives to self-hosted server
/// Contains all essential drive data in a compact format
struct DriveUploadDTO: Codable {
    let driveId: String
    let deviceId: String
    let startTime: String          // ISO8601
    let endTime: String            // ISO8601
    let durationSeconds: Double
    let distanceMeters: Double
    let avgSpeedMPH: Double
    let maxSpeedMPH: Double
    let polyline: String           // Google-encoded
    let pointCount: Int            // Original point count
    let simplifiedPointCount: Int  // After Douglas-Peucker
    let speeds: [Double]           // Speed (MPH) for each simplified point
    let startReason: String?
    let endReason: String?
    
    // MARK: - System Context
    let deviceModel: String?
    let iosVersion: String?
    let appVersion: String?
    
    // MARK: - Quality Metrics (NEW)
    let detectionLatencyMs: Int?       // Time from drive start to first GPS fix (ms)
    let confirmationLatencyMs: Int?    // Time from first fix to confirmed driving speed (ms)
    let locationSampleCount: Int?      // Total GPS samples recorded
    let droppedSampleCount: Int?       // Samples rejected by quality filters
    let maxGapBetweenSamplesMs: Int?   // Longest GPS gap (ms)
    let locationPauseCount: Int?       // Number of iOS location pauses
    let bufferedPointCount: Int?       // Points captured during maybeDriving (route start accuracy)
    let batteryLevelAtStart: Float?    // 0.0 - 1.0
    let batteryLevelAtEnd: Float?      // 0.0 - 1.0
    let lowPowerModeAtStart: Bool?     // Was Low Power Mode enabled?
    
    // MARK: - G-Force Events
    let accelerationEvents: [AccelerationEventUploadDTO]?
    let hardBrakeCount: Int
    let hardAccelCount: Int
    let hardCornerCount: Int
    let maxGForce: Double?
    
    // MARK: - Timeline Events
    let logEntries: [LogEntryDTO]?
    
    /// Create DTO from a Drive model
    /// - Parameters:
    ///   - drive: The completed Drive to upload
    ///   - polyline: Pre-encoded polyline string (from PolylineEncoder)
    ///   - simplifiedCount: Number of points after simplification
    ///   - speeds: Array of speeds (MPH) corresponding to simplified points
    init(from drive: Drive, polyline: String, simplifiedCount: Int, speeds: [Double]) {
        self.driveId = drive.id.uuidString
        self.deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
        
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.startTime = formatter.string(from: drive.startTime)
        self.endTime = formatter.string(from: drive.endTime ?? Date())
        
        self.durationSeconds = drive.duration
        self.distanceMeters = drive.distanceMeters
        self.avgSpeedMPH = drive.averageSpeedMPH
        self.maxSpeedMPH = drive.maxSpeedMPH
        
        self.polyline = polyline
        self.pointCount = drive.points.count
        self.simplifiedPointCount = simplifiedCount
        self.speeds = speeds
        
        self.startReason = drive.startReason?.rawValue
        self.endReason = drive.endReason?.rawValue
        
        // System context
        self.deviceModel = drive.deviceModel
        self.iosVersion = drive.iosVersion
        self.appVersion = drive.appVersion
        
        // Quality metrics
        self.detectionLatencyMs = drive.detectionLatency.map { Int($0 * 1000) }
        self.confirmationLatencyMs = drive.confirmationLatency.map { Int($0 * 1000) }
        self.locationSampleCount = drive.locationSampleCount
        self.droppedSampleCount = drive.droppedSampleCount
        self.maxGapBetweenSamplesMs = drive.maxGapBetweenSamples > 0 ? Int(drive.maxGapBetweenSamples * 1000) : nil
        self.locationPauseCount = drive.locationPauseCount
        self.bufferedPointCount = drive.bufferedPointCount > 0 ? drive.bufferedPointCount : nil
        self.batteryLevelAtStart = drive.batteryLevelAtStart
        self.batteryLevelAtEnd = drive.batteryLevelAtEnd
        self.lowPowerModeAtStart = drive.lowPowerModeAtStart
        
        // G-Force events
        self.accelerationEvents = drive.accelerationEvents.isEmpty ? nil : drive.accelerationEvents.map { AccelerationEventUploadDTO(from: $0) }
        self.hardBrakeCount = drive.hardBrakeCount
        self.hardAccelCount = drive.hardAccelCount
        self.hardCornerCount = drive.hardCornerCount
        self.maxGForce = drive.maxGForce
        
        // Timeline events
        self.logEntries = drive.logEntries.isEmpty ? nil : drive.logEntries.map { LogEntryDTO(from: $0) }
    }
    
    /// Convenience initializer that handles polyline encoding
    init(from drive: Drive) {
        let points = drive.pointsChronological
        // Use simplifyPoints to preserve metadata (speeds)
        let simplifiedPoints = PolylineEncoder.simplifyPoints(points)
        
        let coordinates = simplifiedPoints.map { $0.coordinate }
        let polyline = PolylineEncoder.googleEncode(coordinates)
        
        // Extract speeds (rounded to 1 decimal place for compactness)
        let speeds = simplifiedPoints.map { Double(round($0.speedMPH * 10) / 10) }
        
        self.init(from: drive, polyline: polyline, simplifiedCount: simplifiedPoints.count, speeds: speeds)
    }
}

// MARK: - JSON Helpers

extension DriveUploadDTO {
    /// Encode to JSON data
    func toJSONData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
    
    /// Encode to JSON string (for debugging)
    func toJSONString() -> String? {
        guard let data = try? toJSONData() else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Log Entry DTO

/// DTO for uploading drive timeline events
struct LogEntryDTO: Codable {
    let timestamp: String       // ISO8601
    let category: String        // decision, motion, location, system, anomaly
    let eventType: String       // geofence_exit, motion_automotive, etc.
    let message: String
    let metadata: [String: String]?
    
    init(from entry: DriveLogEntry) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.timestamp = formatter.string(from: entry.timestamp)
        
        self.category = entry.category.rawValue
        self.eventType = entry.eventType
        self.message = entry.message
        self.metadata = entry.metadata
    }
}
