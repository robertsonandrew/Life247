//
//  Drive.swift
//  Life247
//
//  Created by Andrew Robertson on 1/14/26.
//

import Foundation
import SwiftData
import CoreLocation
import MapKit
import UIKit

/// A recorded driving trip.
/// - Created ONLY on `driving` state entry
/// - Finalized ONLY on `ended` state entry
/// - Points appended ONLY while in `driving` state
@Model
final class Drive {
    var id: UUID
    var startTime: Date
    var endTime: Date?
    var distanceMeters: Double
    
    // MARK: - Lifecycle Metadata
    var startReasonRaw: String?     // DriveStartReason.rawValue
    var endReasonRaw: String?       // DriveEndReason.rawValue
    var firstLocationFixTime: Date? // When first GPS fix was received
    var drivingConfirmedTime: Date? // When speed first exceeded threshold
    
    /// When the drive entered stopped state (persisted for recovery).
    /// Used by recoverState() to calculate elapsed stopped time after app restart.
    /// Set when transitioning to .stopped, cleared when resuming to .driving or ending.
    var stoppedSince: Date?
    
    // MARK: - System Context (captured at drive start)
    var iosVersion: String?
    var deviceModel: String?
    var appVersion: String?
    var batteryLevelAtStart: Float? // 0.0 - 1.0
    var batteryLevelAtEnd: Float?
    var lowPowerModeAtStart: Bool?
    
    // MARK: - Quality Metrics
    var locationSampleCount: Int = 0
    var droppedSampleCount: Int = 0
    var maxGapBetweenSamples: TimeInterval = 0
    var locationPauseCount: Int = 0
    var bufferedPointCount: Int = 0  // Points captured during maybeDriving and promoted on drive start
    var distanceGapSkipCount: Int = 0
    var distanceGapSkippedMeters: Double = 0
    
    // MARK: - Sync Status
    var syncedAt: Date?              // When successfully uploaded
    var syncStatus: String?          // "pending", "synced", "failed"
    
    // MARK: - Cached Computed Values (populated at finalization)
    var cachedMaxSpeedMPH: Double = 0
    
    // MARK: - Geocoded Display Names (cached)
    var startNeighborhood: String?   // Cached neighborhood/area name for start
    var endNeighborhood: String?     // Cached neighborhood/area name for end

    // MARK: - End Snapshot (captured at drive end for stop matching)
    var endLatitude: Double?
    var endLongitude: Double?
    var endPlaceId: UUID?
    
    // MARK: - Relationships
    @Relationship(deleteRule: .cascade)
    var points: [LocationPoint]
    
    @Relationship(deleteRule: .cascade, inverse: \DriveLogEntry.drive)
    var logEntries: [DriveLogEntry]
    
    @Relationship(deleteRule: .cascade, inverse: \AccelerationEvent.drive)
    var accelerationEvents: [AccelerationEvent]
    
    init(
        id: UUID = UUID(),
        startTime: Date = Date(),
        endTime: Date? = nil,
        distanceMeters: Double = 0,
        points: [LocationPoint] = [],
        logEntries: [DriveLogEntry] = [],
        accelerationEvents: [AccelerationEvent] = []
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.distanceMeters = distanceMeters
        self.points = points
        self.logEntries = logEntries
        self.accelerationEvents = accelerationEvents
        
        // Capture system context at creation
        self.iosVersion = ProcessInfo.processInfo.operatingSystemVersionString
        self.deviceModel = Self.deviceModelIdentifier
        self.appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        self.batteryLevelAtStart = Self.currentBatteryLevel
        self.lowPowerModeAtStart = ProcessInfo.processInfo.isLowPowerModeEnabled
    }
    
    // MARK: - Lifecycle Computed Properties
    
    var startReason: DriveStartReason? {
        get { startReasonRaw.flatMap { DriveStartReason(rawValue: $0) } }
        set { startReasonRaw = newValue?.rawValue }
    }
    
    var endReason: DriveEndReason? {
        get { endReasonRaw.flatMap { DriveEndReason(rawValue: $0) } }
        set { endReasonRaw = newValue?.rawValue }
    }
    
    /// Time from drive start to first GPS fix
    var detectionLatency: TimeInterval? {
        guard let fixTime = firstLocationFixTime else { return nil }
        return fixTime.timeIntervalSince(startTime)
    }
    
    /// Time from first GPS fix to confirmed driving speed
    var confirmationLatency: TimeInterval? {
        guard let fixTime = firstLocationFixTime,
              let confirmedTime = drivingConfirmedTime else { return nil }
        return confirmedTime.timeIntervalSince(fixTime)
    }
    
    /// Log entries sorted chronologically
    var logEntriesChronological: [DriveLogEntry] {
        logEntries.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp {
                return lhs.timestamp < rhs.timestamp
            }
            let lhsSeq = lhs.sequenceNumber ?? Int.max
            let rhsSeq = rhs.sequenceNumber ?? Int.max
            if lhsSeq != rhsSeq {
                return lhsSeq < rhsSeq
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
    
    // MARK: - System Helpers
    
    private static var deviceModelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        return machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
    }
    
    private static var currentBatteryLevel: Float {
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        return UIDevice.current.batteryLevel
        #else
        return -1
        #endif
    }
    
    // MARK: - Computed Properties
    
    /// Duration of the drive
    var duration: TimeInterval {
        (endTime ?? Date()).timeIntervalSince(startTime)
    }
    
    /// Duration formatted as HH:MM:SS
    var formattedDuration: String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
    
    /// Distance in miles
    var distanceMiles: Double {
        distanceMeters / 1609.344
    }
    
    /// Formatted distance string
    var formattedDistance: String {
        String(format: "%.1f mi", distanceMiles)
    }
    
    /// Average speed in MPH (based on distance and duration)
    var averageSpeedMPH: Double {
        guard duration > 0 else { return 0 }
        return distanceMiles / (duration / 3600)
    }
    
    /// Maximum speed recorded in MPH (uses cached value if available)
    var maxSpeedMPH: Double {
        if cachedMaxSpeedMPH > 0 { return cachedMaxSpeedMPH }
        return points.map { $0.speedMPH }.max() ?? 0
    }
    
    /// Start coordinate for map display
    var startCoordinate: CLLocationCoordinate2D? {
        pointsChronological.first?.coordinate
    }
    
    /// End coordinate for map display
    var endCoordinate: CLLocationCoordinate2D? {
        latestPointForProcessing()?.coordinate
    }

    /// End coordinate snapshot captured at drive end (may differ from last point)
    var endCoordinateSnapshot: CLLocationCoordinate2D? {
        if let lat = endLatitude, let lon = endLongitude {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        return pointsChronological.last?.coordinate
    }
    
    /// Short identifier for debugging (first 4 chars of UUID)
    var shortId: String {
        String(id.uuidString.prefix(4))
    }
    
    /// Whether this drive is still in progress
    var isActive: Bool {
        endTime == nil
    }
    
    // MARK: - Acceleration Event Summaries
    
    /// Count of hard braking events
    var hardBrakeCount: Int {
        accelerationEvents.filter { $0.eventType == .hardBrake }.count
    }
    
    /// Count of hard acceleration events
    var hardAccelCount: Int {
        accelerationEvents.filter { $0.eventType == .hardAcceleration }.count
    }
    
    /// Count of hard cornering events (left + right)
    var hardCornerCount: Int {
        accelerationEvents.filter { $0.eventType == .hardCornerLeft || $0.eventType == .hardCornerRight }.count
    }
    
    /// Maximum G-force recorded during this drive
    var maxGForce: Double? {
        accelerationEvents.map { $0.gForceMagnitude }.max()
    }
    
    /// Summary of acceleration events for display
    var accelerationSummary: String? {
        let total = accelerationEvents.count
        guard total > 0 else { return nil }
        return "\(hardBrakeCount) brakes, \(hardAccelCount) accels, \(hardCornerCount) corners"
    }
    
    /// Cached sorted points - invalidated when points change
    /// Access via pointsChronological property
    @Transient
    private var _cachedSortedPoints: [LocationPoint]?
    @Transient
    private var _cachedPointsCount: Int = -1
    @Transient
    private var _cachedLatestPoint: LocationPoint?
    @Transient
    private var _cachedLatestPointCount: Int = -1
    
    /// Points in chronological order (SwiftData relationships don't preserve insertion order)
    /// Uses latitude as tie-breaker for stable ordering when timestamps are equal
    /// Invalidate the cached sorted points (call after modifying points directly)
    func invalidatePointsCache() {
        _cachedSortedPoints = nil
        _cachedPointsCount = -1
        _cachedLatestPoint = nil
        _cachedLatestPointCount = -1
    }
    
    /// Points in chronological order (SwiftData relationships don't preserve insertion order)
    /// Uses latitude as tie-breaker for stable ordering when timestamps are equal
    /// Caches result and invalidates when points.count changes
    var pointsChronological: [LocationPoint] {
        // Invalidate cache if points count changed
        if _cachedPointsCount != points.count {
            _cachedSortedPoints = nil
        }
        
        if let cached = _cachedSortedPoints {
            return cached
        }
        
        let sorted = points.sorted {
            if $0.timestamp == $1.timestamp {
                return $0.latitude < $1.latitude
            }
            return $0.timestamp < $1.timestamp
        }
        _cachedSortedPoints = sorted
        _cachedPointsCount = points.count
        return sorted
    }

    /// Timestamp of the most recent accepted point (order-safe for unordered relationships).
    var latestPointTimestamp: Date? {
        latestPointForProcessing()?.timestamp
    }

    private func latestPointForProcessing() -> LocationPoint? {
        guard !points.isEmpty else {
            _cachedLatestPoint = nil
            _cachedLatestPointCount = 0
            return nil
        }

        if _cachedLatestPointCount == points.count, let cached = _cachedLatestPoint {
            return cached
        }

        let latest = points.max { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                return lhs.latitude < rhs.latitude
            }
            return lhs.timestamp < rhs.timestamp
        }

        _cachedLatestPoint = latest
        _cachedLatestPointCount = points.count
        return latest
    }

    private func updateLatestPointCache(with point: LocationPoint) {
        if let current = _cachedLatestPoint {
            if point.timestamp > current.timestamp ||
                (point.timestamp == current.timestamp && point.latitude >= current.latitude) {
                _cachedLatestPoint = point
            }
        } else {
            _cachedLatestPoint = point
        }
        _cachedLatestPointCount = points.count
    }
    
    /// Precomputed route bounds for efficient camera fitting
    var routeBounds: (center: CLLocationCoordinate2D, span: MKCoordinateSpan)? {
        let coords = pointsChronological.map { $0.coordinate }
        guard coords.count > 1 else { return nil }
        
        let lats = coords.map { $0.latitude }
        let lons = coords.map { $0.longitude }
        
        guard let minLat = lats.min(),
              let maxLat = lats.max(),
              let minLon = lons.min(),
              let maxLon = lons.max() else { return nil }
        
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: (maxLat - minLat) * 1.3 + 0.005,
            longitudeDelta: (maxLon - minLon) * 1.3 + 0.005
        )
        return (center, span)
    }
    
    /// Sampled points for mini maps (1 point per ~50 meters equivalent)
    /// Reduces point count for performance in list views
    func sampledPoints(maxCount: Int = 100) -> [LocationPoint] {
        let chronological = pointsChronological
        guard chronological.count > maxCount else { return chronological }
        
        let stride = chronological.count / maxCount
        return chronological.enumerated()
            .filter { $0.offset % stride == 0 || $0.offset == chronological.count - 1 }
            .map { $0.element }
    }
    
    // MARK: - Methods
    
    /// Minimum horizontal accuracy to accept a point (meters).
    /// Shared with DriveStateMachine for consistent filtering.
    static let maxAccuracy: Double = 30.0
    
    /// Maximum reasonable speed to filter GPS spikes (meters/second) - ~150 mph
    private static let maxReasonableSpeed: Double = 67.0
    
    /// Maximum distance jump between consecutive points (meters) - helps filter teleports
    private static let maxDistanceJump: Double = 500.0
    
    /// Don't accumulate distance across very large sample gaps (seconds)
    /// Prevents inflated totals when iOS batches sparse background updates.
    private static let maxGapForDistanceAccumulation: TimeInterval = 90
    
    /// Reason why a location point was rejected
    enum PointRejectionReason: String {
        case poorAccuracy = "accuracy"
        case invalidSpeed = "invalid_speed"
        case speedTooHigh = "speed_spike"
        case timeDeltaInvalid = "time_delta"
        case teleportation = "teleport"
    }

    /// Non-fatal handling details for accepted points
    enum PointAcceptanceNote {
        case distanceSkippedLargeGap(gapSeconds: TimeInterval, skippedMeters: Double)
    }
    
    /// Add a location point if it passes quality filters
    /// Returns true if point was added, false if rejected
    @discardableResult
    func addPoint(_ location: CLLocation) -> Bool {
        return addPointWithReason(location).0
    }
    
    /// Add a location point if it passes quality filters
    /// Returns (success, rejectionReason, acceptanceNote)
    /// - rejectionReason is nil if accepted
    /// - acceptanceNote provides additional context for accepted points
    func addPointWithReason(_ location: CLLocation) -> (Bool, PointRejectionReason?, PointAcceptanceNote?) {
        // Filter 1: Reject poor accuracy readings
        guard location.horizontalAccuracy > 0 && location.horizontalAccuracy <= Self.maxAccuracy else {
            return (false, .poorAccuracy, nil)
        }

        // Filter 2: Reject impossibly high speeds (GPS spike) when speed is reported.
        // Note: CLLocation.speed may be -1 (invalid), especially during background samples.
        if location.speed >= 0 {
            guard location.speed <= Self.maxReasonableSpeed else {
                return (false, .speedTooHigh, nil)
            }
        }
        
        // Filter 4: If we have previous points, check for impossible jumps
        if let lastPoint = latestPointForProcessing() {
            let lastLocation = CLLocation(
                latitude: lastPoint.latitude,
                longitude: lastPoint.longitude
            )
            let distance = location.distance(from: lastLocation)
            let timeDelta = location.timestamp.timeIntervalSince(lastPoint.timestamp)
            
            // Reject if time went backwards or is stale
            guard timeDelta > 0 else {
                return (false, .timeDeltaInvalid, nil)
            }

            // Very large gaps are treated as unknown movement windows.
            // Keep the point for route continuity, but skip distance accumulation.
            if timeDelta > Self.maxGapForDistanceAccumulation {
                let impliedSpeed = distance / timeDelta
                if impliedSpeed > Self.maxReasonableSpeed {
                    return (false, .teleportation, nil)
                }
                let newPoint = LocationPoint(from: location)
                points.append(newPoint)
                invalidatePointsCache()
                updateLatestPointCache(with: newPoint)
                distanceGapSkipCount += 1
                distanceGapSkippedMeters += distance
                return (true, nil, .distanceSkippedLargeGap(gapSeconds: timeDelta, skippedMeters: distance))
            }
            
            // Reject teleportation (jumped too far too fast)
            if distance > Self.maxDistanceJump {
                // Check if implied speed is reasonable
                let impliedSpeed = distance / timeDelta
                if impliedSpeed > Self.maxReasonableSpeed {
                    return (false, .teleportation, nil)
                }
                // Large gap but plausible speed (GPS gap) — accept and count distance
                distanceMeters += distance
            } else {
                // Normal delta — count distance
                distanceMeters += distance
            }
        }
        
        // Point passed all filters - add it
        let newPoint = LocationPoint(from: location)
        points.append(newPoint)
        invalidatePointsCache()
        updateLatestPointCache(with: newPoint)
        return (true, nil, nil)
    }
    
    /// Finalize the drive with an end time and optional reason
    func finalize(endReason: DriveEndReason? = nil) {
        endTime = Date()
        if let reason = endReason {
            self.endReason = reason
        }
        // Clear stoppedSince since drive is now ended
        stoppedSince = nil
        
        // Pre-compute expensive values for fast access in history views
        cachedMaxSpeedMPH = points.map { $0.speedMPH }.max() ?? 0
    }
    
    // MARK: - Geocoding
    
    /// Dynamic title based on geocoded neighborhoods (e.g., "Bixby → Broken Arrow")
    var dynamicTitle: String {
        if let start = startNeighborhood, let end = endNeighborhood {
            if start == end {
                // Same neighborhood - indicate it's a local trip
                return "\(start) area"
            }
            return "\(start) → \(end)"
        }
        return "Drive"
    }
    
    /// Whether this drive qualifies as a "micro" trip (short repositioning)
    var isMicroTrip: Bool {
        distanceMiles < 0.2 || duration < 120
    }
    
    /// Fetch and cache neighborhood names from coordinates
    @MainActor
    func fetchNeighborhoodsIfNeeded() async {
        // Skip if already fetched
        guard startNeighborhood == nil || endNeighborhood == nil else { return }
        guard let startCoord = startCoordinate, let endCoord = endCoordinateSnapshot else { return }
        
        async let startName = Self.fetchNeighborhood(for: startCoord)
        async let endName = Self.fetchNeighborhood(for: endCoord)
        
        let (start, end) = await (startName, endName)
        
        if startNeighborhood == nil {
            startNeighborhood = start
        }
        if endNeighborhood == nil {
            endNeighborhood = end
        }
    }
    
    /// Reverse geocode a coordinate to get neighborhood/locality name
    private static func fetchNeighborhood(for coordinate: CLLocationCoordinate2D) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let geocoder = CLGeocoder()
        
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            guard let placemark = placemarks.first else { return nil }
            
            // Priority: subLocality (neighborhood) > locality (city) > subAdministrativeArea
            if let neighborhood = placemark.subLocality {
                return neighborhood
            }
            if let city = placemark.locality {
                return city
            }
            if let area = placemark.subAdministrativeArea {
                return area
            }
            return nil
        } catch {
            return nil
        }
    }
}
