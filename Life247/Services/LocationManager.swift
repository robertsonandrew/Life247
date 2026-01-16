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
    
    // MARK: - Private Properties
    
    private let locationManager = CLLocationManager()
    private let logger = Logger(subsystem: "com.life247", category: "LocationManager")
    private weak var eventSink: LocationEventSink?
    
    /// Current location accuracy mode
    private var isHighAccuracyMode: Bool = false
    
    // MARK: - Initialization
    
    override init() {
        super.init()
        locationManager.delegate = self
        // Note: allowsBackgroundLocationUpdates is set when starting high-accuracy mode
        // Setting it in init crashes if background capability isn't configured
        authorizationStatus = locationManager.authorizationStatus
    }
    
    /// Set the event sink for location events
    func setEventSink(_ sink: LocationEventSink) {
        self.eventSink = sink
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
    func startMonitoring() {
        guard hasAnyAuthorization else {
            logger.warning("Cannot start monitoring - no authorization")
            return
        }
        
        logger.info("Starting significant location change monitoring")
        locationManager.startMonitoringSignificantLocationChanges()
        locationManager.startMonitoringVisits()
        isMonitoring = true
    }
    
    /// Stop all location monitoring
    func stopMonitoring() {
        logger.info("Stopping all location monitoring")
        locationManager.stopMonitoringSignificantLocationChanges()
        locationManager.stopMonitoringVisits()
        locationManager.stopUpdatingLocation()
        isMonitoring = false
        isHighAccuracyMode = false
    }
    
    /// Switch to high-accuracy mode for active tracking
    func enableHighAccuracyMode() {
        guard !isHighAccuracyMode else { return }
        guard hasAnyAuthorization else {
            logger.warning("Cannot enable high-accuracy mode - no authorization")
            return
        }
        
        logger.info("Enabling high-accuracy location mode")
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 5 // meters - reduced for smoother tracking
        locationManager.activityType = .automotiveNavigation // iOS optimizes for vehicle
        
        // Enable background updates only when we need high-accuracy tracking
        // This requires the "location" UIBackgroundModes capability
        if hasAlwaysAuthorization {
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.pausesLocationUpdatesAutomatically = false
            locationManager.showsBackgroundLocationIndicator = true
        }
        
        locationManager.startUpdatingLocation()
        isHighAccuracyMode = true
    }
    
    /// Switch to low-power mode for background monitoring
    func disableHighAccuracyMode() {
        guard isHighAccuracyMode else { return }
        
        logger.info("Disabling high-accuracy location mode")
        locationManager.stopUpdatingLocation()
        isHighAccuracyMode = false
        
        // Ensure SLC is still running
        if hasAlwaysAuthorization {
            locationManager.startMonitoringSignificantLocationChanges()
        }
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
        guard let location = locations.last else { return }
        
        // Request background execution time for SLC wakes
        var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "SLCWakeProcessing") {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
        
        Task { @MainActor in
            logger.debug("Location update: \(location.coordinate.latitude), \(location.coordinate.longitude) @ \(location.speed)m/s")
            eventSink?.handle(.locationUpdate(location))
            
            // End background task after event is processed
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
            }
        }
    }
    
    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        Task { @MainActor in
            if visit.departureDate != Date.distantFuture {
                logger.info("Visit departure: \(visit.coordinate.latitude), \(visit.coordinate.longitude)")
                eventSink?.handle(.visitDeparture)
            } else {
                logger.info("Visit arrival: \(visit.coordinate.latitude), \(visit.coordinate.longitude)")
                eventSink?.handle(.visitArrival)
            }
        }
    }
    
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            logger.error("Location manager error: \(error.localizedDescription)")
        }
    }
}
