//
//  LocationManager.swift
//  Life247
//
//  Created by Andrew Robertson on 1/14/26.
//

import Foundation
import CoreLocation
import Combine
import OSLog
import UIKit

/// Protocol for receiving drive events from LocationManager
protocol LocationEventSink: AnyObject {
    @MainActor func handle(_ event: DriveEvent)
}

/// Passive location provider.
/// Responsibilities: Permissions, mode switching, delivering raw location events.
/// Forbidden: Speed thresholds, drive detection logic, persistence.
final class LocationManager: NSObject, ObservableObject {
    
    // MARK: - Published State
    
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var isMonitoring: Bool = false
    @Published private(set) var currentHeading: CLHeading?
    
    // MARK: - Private Properties
    
    private let locationManager = CLLocationManager()
    private let logger = Logger(subsystem: "com.life247", category: "LocationManager")
    private weak var eventSink: LocationEventSink?
    private weak var motionManager: MotionManager?
    
    /// Location filter for jitter suppression (location events route through this)
    private weak var locationFilter: LocationFilter?
    
    /// Current location accuracy mode
    private(set) var isHighAccuracyMode: Bool = false

    /// Source-side heading throttling to avoid over-publishing compass updates.
    private let minHeadingPublishInterval: TimeInterval = 0.10
    private let minHeadingDeltaDegrees: CLLocationDirection = 1.5
    private var lastPublishedHeadingAt: Date = .distantPast
    private var lastPublishedHeadingDegrees: CLLocationDirection?
    
    // MARK: - Initialization
    
    override init() {
        super.init()
        locationManager.delegate = self
        // Note: allowsBackgroundLocationUpdates is set when starting high-accuracy mode
        // Setting it in init crashes if background capability isn't configured
        authorizationStatus = locationManager.authorizationStatus
    }
    
    /// Set the event sink for non-location events (geofence, visits)
    func setEventSink(_ sink: LocationEventSink) {
        self.eventSink = sink
    }
    
    /// Set the location filter for location events
    func setLocationFilter(_ filter: LocationFilter) {
        self.locationFilter = filter
    }

    /// Set motion manager for raw GPS feed (G-force detection)
    func setMotionManager(_ manager: MotionManager) {
        self.motionManager = manager
    }
    
    // MARK: - Permissions
    
    /// Request always authorization
    @MainActor
    func requestAuthorization() {
        logger.info("Requesting location authorization")
        locationManager.requestAlwaysAuthorization()
    }
    
    /// Check if we have always authorization
    @MainActor
    var hasAlwaysAuthorization: Bool {
        authorizationStatus == .authorizedAlways
    }
    
    /// Check if we have any location authorization
    @MainActor
    var hasAnyAuthorization: Bool {
        authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse
    }
    
    // MARK: - Monitoring Control
    
    /// Start background location monitoring (low power)
    @MainActor
    func startMonitoring() {
        guard hasAnyAuthorization else {
            logger.warning("Cannot start monitoring - no authorization")
            return
        }
        
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            logger.info("Starting significant location change monitoring")
            locationManager.startMonitoringSignificantLocationChanges()
        } else {
            logger.warning("Significant location change monitoring not available")
        }
        locationManager.startMonitoringVisits()
        isMonitoring = true
    }
    
    /// Stop all location monitoring
    @MainActor
    func stopMonitoring() {
        logger.info("Stopping all location monitoring")
        locationManager.stopMonitoringSignificantLocationChanges()
        locationManager.stopMonitoringVisits()
        locationManager.stopUpdatingLocation()
        isMonitoring = false
        isHighAccuracyMode = false
    }
    
    /// Reasons for keeping high accuracy active
    private var highAccuracyReasons: Set<String> = []
    
    /// Enable high-accuracy mode for a specific reason
    @MainActor
    func enableHighAccuracy(reason: String) {
        let wasEmpty = highAccuracyReasons.isEmpty
        let (inserted, _) = highAccuracyReasons.insert(reason)
        if inserted {
            logger.info("High-accuracy requested for: \(reason) (active: \(self.highAccuracyReasons))")
        }
        if wasEmpty && !highAccuracyReasons.isEmpty {
            startHighAccuracyTracking()
        }
    }
    
    /// Disable high-accuracy mode for a specific reason
    @MainActor
    func disableHighAccuracy(reason: String) {
        // Guard against redundant releases
        guard highAccuracyReasons.contains(reason) else {
            return  // Silently ignore - already released or never requested
        }
        
        highAccuracyReasons.remove(reason)
        logger.info("High-accuracy release for: \(reason) (remaining: \(self.highAccuracyReasons))")
        
        if highAccuracyReasons.isEmpty && isHighAccuracyMode {
            stopHighAccuracyTracking()
        }
    }
    
    // Legacy support (redirects to "manual")
    @MainActor func enableHighAccuracyMode() { enableHighAccuracy(reason: "manual") }
    @MainActor func disableHighAccuracyMode() { disableHighAccuracy(reason: "manual") }
    
    private func startHighAccuracyTracking() {
        guard !isHighAccuracyMode else { return }
        guard hasAnyAuthorization else {
            logger.warning("Cannot enable high-accuracy mode - no authorization")
            return
        }
        
        logger.info("Starting high-accuracy location tracking")
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 2 // meters - smoother interpolation at higher frequency
        locationManager.activityType = .automotiveNavigation // iOS optimizes for vehicle
        
        // Enable background updates only when we need high-accuracy tracking
        // This requires the "location" UIBackgroundModes capability
        if hasAlwaysAuthorization {
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.pausesLocationUpdatesAutomatically = false
            locationManager.showsBackgroundLocationIndicator = true
        }
        
        locationManager.startUpdatingLocation()
        
        // Start compass updates if available (for stopped-state puck orientation)
        if CLLocationManager.headingAvailable() {
            lastPublishedHeadingAt = .distantPast
            lastPublishedHeadingDegrees = nil
            locationManager.startUpdatingHeading()
        }
        
        isHighAccuracyMode = true
    }
    
    private func stopHighAccuracyTracking() {
        guard isHighAccuracyMode else { return }
        
        logger.info("Stopping high-accuracy location tracking")
        locationManager.stopUpdatingLocation()
        locationManager.stopUpdatingHeading()
        if hasAlwaysAuthorization {
            locationManager.showsBackgroundLocationIndicator = false
            locationManager.allowsBackgroundLocationUpdates = false
            locationManager.pausesLocationUpdatesAutomatically = true
        }
        currentHeading = nil
        lastPublishedHeadingAt = .distantPast
        lastPublishedHeadingDegrees = nil
        isHighAccuracyMode = false
        
        // Ensure SLC is still running
        if hasAlwaysAuthorization {
            locationManager.startMonitoringSignificantLocationChanges()
        }
    }
    
    // MARK: - One-Shot GPS
    
    private var oneShotTask: Task<Void, Never>?
    private var isOneShotActive: Bool = false
    
    /// Request a single high-accuracy location fix, then auto-disable.
    /// Idempotent: if a one-shot is already active, this is a no-op.
    @MainActor
    func requestOneShotLocation(reason: String) {
        // Idempotent guard: don't stack requests
        guard !isOneShotActive else {
            logger.debug("[ONE-SHOT] Skipping - already active")
            return
        }
        
        logger.info("[ONE-SHOT] Starting GPS window for: \(reason)")
        isOneShotActive = true
        
        enableHighAccuracy(reason: "oneShot")
        
        // Auto-disable after 10 seconds
        oneShotTask = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self.endOneShotLocation()
        }
    }
    
    /// Cancel an active one-shot GPS request.
    /// Called on state change to avoid wasted GPS when drive already started.
    @MainActor
    func cancelOneShotLocation() {
        guard isOneShotActive else { return }
        logger.info("[ONE-SHOT] Cancelled (state changed)")
        endOneShotLocation()
    }
    
    private func endOneShotLocation() {
        oneShotTask?.cancel()
        oneShotTask = nil
        isOneShotActive = false
        disableHighAccuracy(reason: "oneShot")
    }
    
    // MARK: - Geofencing

    /// Reliability floor for region monitoring radius.
    /// iOS can under-deliver very small geofences in background depending on conditions.
    private static let geofenceReliabilityFloorMeters: CLLocationDistance = 75
    private static let geofenceAccuracyBufferScale: Double = 1.25
    private static let geofenceAccuracyBufferCapMeters: CLLocationDistance = 120
    private static let geofenceUserMinMeters: CLLocationDistance = Place.minUserRadiusMeters
    private static let geofenceUserMaxMeters: CLLocationDistance = Place.maxUserRadiusMeters

    /// Best available current coordinate from CoreLocation cache.
    @MainActor
    var currentCoordinate: CLLocationCoordinate2D? {
        locationManager.location?.coordinate
    }

    /// Best available horizontal accuracy from CoreLocation cache.
    @MainActor
    var currentHorizontalAccuracy: CLLocationAccuracy? {
        guard let accuracy = locationManager.location?.horizontalAccuracy, accuracy > 0 else {
            return nil
        }
        return accuracy
    }

    /// Shared monitoring-radius policy used by registration and UI.
    static func recommendedMonitoringRadius(
        forUserRadiusMeters userRadiusMeters: CLLocationDistance,
        horizontalAccuracy: CLLocationAccuracy? = nil,
        maxSupportedRadius: CLLocationDistance = .greatestFiniteMagnitude
    ) -> CLLocationDistance {
        let clampedUserRadius = min(geofenceUserMaxMeters, max(geofenceUserMinMeters, userRadiusMeters))

        let accuracyBuffer: CLLocationDistance
        if let horizontalAccuracy, horizontalAccuracy > 0 {
            accuracyBuffer = min(
                geofenceAccuracyBufferCapMeters,
                max(0, horizontalAccuracy * geofenceAccuracyBufferScale)
            )
        } else {
            accuracyBuffer = 0
        }

        let desiredRadius = max(clampedUserRadius, geofenceReliabilityFloorMeters, accuracyBuffer)
        let supportedCeiling = max(geofenceReliabilityFloorMeters, maxSupportedRadius)
        return min(desiredRadius, supportedCeiling)
    }

    /// Compute geofence monitoring radius from user radius + runtime conditions.
    /// This is intentionally separate from place containment/display radius.
    @MainActor
    func monitoringRadius(forUserRadiusMeters userRadiusMeters: CLLocationDistance) -> CLLocationDistance {
        Self.recommendedMonitoringRadius(
            forUserRadiusMeters: userRadiusMeters,
            horizontalAccuracy: locationManager.location?.horizontalAccuracy,
            maxSupportedRadius: locationManager.maximumRegionMonitoringDistance
        )
    }
    
    /// Sync monitored regions with the provided list of circular regions
    /// - Parameter forceRefresh: If true, re-registers all regions to update their settings (entry/exit notifications)
    @MainActor
    func updateMonitoredRegions(_ regions: [CLCircularRegion], forceRefresh: Bool = false) {
        guard hasAlwaysAuthorization else { return }
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        
        let currentlyMonitored = locationManager.monitoredRegions
        var currentIds = Set(currentlyMonitored.map { $0.identifier })
        let targetIds = Set(regions.map { $0.identifier })
        
        // Remove stale regions (or all if force refreshing)
        for region in currentlyMonitored {
            if forceRefresh || !targetIds.contains(region.identifier) {
                logger.info("Stopping monitoring for region: \(region.identifier)\(forceRefresh ? " (refresh)" : "")")
                locationManager.stopMonitoring(for: region)
                currentIds.remove(region.identifier)
            }
        }
        
        // Add new regions (or all if force refreshing)
        // Note: iOS limits to 20 monitored regions per app
        var count = currentIds.count
        for region in regions {
            if count >= 20 {
                logger.warning("Max monitored regions (20) reached. Skipping: \(region.identifier)")
                continue
            }
            if forceRefresh || !currentIds.contains(region.identifier) {
                region.notifyOnExit = true
                region.notifyOnEntry = true  // Also notify on entry to end drives
                logger.info("Starting monitoring for region: \(region.identifier)")
                locationManager.startMonitoring(for: region)
                count += 1
            }
        }
    }

    @MainActor
    private func shouldPublishHeading(_ heading: CLHeading) -> Bool {
        guard let headingDegrees = preferredHeadingDegrees(from: heading) else { return false }
        let now = Date()

        guard now.timeIntervalSince(lastPublishedHeadingAt) >= minHeadingPublishInterval else {
            return false
        }

        if let lastPublishedHeadingDegrees {
            let delta = abs(shortestHeadingDelta(from: lastPublishedHeadingDegrees, to: headingDegrees))
            guard delta >= minHeadingDeltaDegrees else { return false }
        }

        lastPublishedHeadingAt = now
        lastPublishedHeadingDegrees = headingDegrees
        return true
    }

    private func preferredHeadingDegrees(from heading: CLHeading) -> CLLocationDirection? {
        if heading.trueHeading >= 0 {
            return normalizedHeading(heading.trueHeading)
        }
        if heading.magneticHeading >= 0 {
            return normalizedHeading(heading.magneticHeading)
        }
        return nil
    }

    private func normalizedHeading(_ value: CLLocationDirection) -> CLLocationDirection {
        let normalized = value.truncatingRemainder(dividingBy: 360)
        return normalized < 0 ? normalized + 360 : normalized
    }

    private func shortestHeadingDelta(from: CLLocationDirection, to: CLLocationDirection) -> CLLocationDirection {
        var delta = normalizedHeading(to) - normalizedHeading(from)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationManager: CLLocationManagerDelegate {
    
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let status = manager.authorizationStatus
            logger.info("Authorization changed: \(String(describing: status.rawValue))")
            authorizationStatus = status
            
            if hasAlwaysAuthorization && !isMonitoring {
                startMonitoring()
            }
        }
    }
    
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard !locations.isEmpty else { return }

        Task { @MainActor in
            // If we're in low-power mode (SLC + visits), treat this update as an SLC wake for logging/diagnostics.
            // In high-accuracy mode, we get continuous updates and should not emit SLC events.
            if !isHighAccuracyMode {
                locationFilter?.forward(.significantLocationChange) ?? eventSink?.handle(.significantLocationChange)
            }

            // Request background execution time only when not active.
            // In foreground, this adds overhead and can degrade battery/perf.
            let shouldUseBackgroundTask = UIApplication.shared.applicationState != .active
            var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
            if shouldUseBackgroundTask {
                backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "LocationWakeProcessing") {
                    UIApplication.shared.endBackgroundTask(backgroundTaskID)
                    backgroundTaskID = .invalid
                }
            }

            let sortedLocations = locations.sorted { $0.timestamp < $1.timestamp }
            if sortedLocations.count > 1 {
                logger.debug("Location batch: \(sortedLocations.count) updates")
            }

            for location in sortedLocations {
                // Feed raw GPS to accelerometer detector (bypasses filter)
                motionManager?.updateAccelerometerGPS(location)

                // Route through filter for jitter suppression (falls back to direct if no filter)
                if let filter = locationFilter {
                    filter.process(location, isHighAccuracyMode: isHighAccuracyMode)
                } else {
                    eventSink?.handle(.locationUpdate(location))
                }
            }

            if shouldUseBackgroundTask {
                // Brief delay to ensure state machine async work (timers, saves) can complete.
                // This is especially important during SLC wakes where iOS may suspend quickly.
                try? await Task.sleep(for: .milliseconds(500))

                // End background task after event is processed
                if backgroundTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTaskID)
                }
            }
        }
    }
    
    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        Task { @MainActor in
            if visit.departureDate != Date.distantFuture {
                logger.info("Visit departure: \(visit.coordinate.latitude), \(visit.coordinate.longitude)")
                eventSink?.handle(.visitDeparture(visit))
            } else {
                logger.info("Visit arrival: \(visit.coordinate.latitude), \(visit.coordinate.longitude)")
                eventSink?.handle(.visitArrival(visit))
            }
        }
    }
    
    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        Task { @MainActor in
            let shouldUseBackgroundTask = UIApplication.shared.applicationState != .active
            var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
            if shouldUseBackgroundTask {
                backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "GeofenceExit") {
                    UIApplication.shared.endBackgroundTask(backgroundTaskID)
                    backgroundTaskID = .invalid
                }
            }

            logger.info("Geofence EXIT: \(region.identifier)")
            eventSink?.handle(.geofenceExit(regionId: region.identifier))

            if shouldUseBackgroundTask {
                // Brief delay to ensure state machine can react
                try? await Task.sleep(for: .milliseconds(500))
                
                if backgroundTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTaskID)
                }
            }
        }
    }
    
    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        Task { @MainActor in
            let shouldUseBackgroundTask = UIApplication.shared.applicationState != .active
            var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
            if shouldUseBackgroundTask {
                backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "GeofenceEntry") {
                    UIApplication.shared.endBackgroundTask(backgroundTaskID)
                    backgroundTaskID = .invalid
                }
            }

            logger.info("Geofence ENTRY: \(region.identifier) - Arrived at saved place")
            eventSink?.handle(.geofenceEntry(regionId: region.identifier))

            if shouldUseBackgroundTask {
                // Brief delay to ensure state machine can react
                try? await Task.sleep(for: .milliseconds(500))
                
                if backgroundTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTaskID)
                }
            }
        }
    }
    
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        Task { @MainActor in
            // Only accept heading if calibration is reasonable (headingAccuracy >= 0 means valid)
            guard newHeading.headingAccuracy >= 0 else {
                logger.debug("Heading update ignored: calibration required")
                return
            }
            guard shouldPublishHeading(newHeading) else { return }
            currentHeading = newHeading
        }
    }
    
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            logger.error("Location manager error: \(error.localizedDescription)")
        }
    }

    nonisolated func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor in
            logger.info("Location updates paused by iOS")
            eventSink?.handle(.locationUpdatesPaused)
        }
    }

    nonisolated func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor in
            logger.info("Location updates resumed by iOS")
            eventSink?.handle(.locationUpdatesResumed)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didStartMonitoringFor region: CLRegion) {
        Task { @MainActor in
            logger.info("Started monitoring region: \(region.identifier)")
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        Task { @MainActor in
            let id = region?.identifier ?? "<unknown>"
            logger.error("Region monitoring failed for \(id): \(error.localizedDescription)")
        }
    }
}
