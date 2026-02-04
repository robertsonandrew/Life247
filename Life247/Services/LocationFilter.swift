//
//  LocationFilter.swift
//  Life247
//
//  Created by Andrew Robertson on 1/29/26.
//

import Foundation
import CoreLocation
import Combine
import OSLog

/// Centralized location filter that reduces GPS jitter for all consumers.
/// Sits between LocationManager and DriveStateMachine to provide stable,
/// filtered locations for camera, puck, and drive logic.
///
/// Filtering rules:
/// - Jitter suppression: When stationary (speed < threshold), ignore updates
///   where distance moved is less than horizontal accuracy
/// - Accuracy gating: Reject updates with poor horizontal accuracy
/// - Staleness rejection: Reject locations older than threshold
@MainActor
final class LocationFilter: ObservableObject {
    
    // MARK: - Configuration
    
    /// Maximum acceptable horizontal accuracy (meters)
    private let maxAccuracy: CLLocationAccuracy = 25.0
    
    /// Maximum age for accepting a location (seconds)
    private let maxLocationAge: TimeInterval = 12.0
    
    /// Speed threshold for "stationary" detection (m/s) ~1.1 mph
    private let stationarySpeedThreshold: CLLocationSpeed = 0.5
    
    /// Minimum distance (meters) to accept when stationary
    /// If movement is less than this AND we're stopped, ignore the update
    private let jitterThreshold: CLLocationDistance = 3.0
    
    // MARK: - State
    
    /// Last accepted (filtered) location
    @Published private(set) var filteredLocation: CLLocation?
    
    /// The downstream event sink (DriveStateMachine)
    private weak var eventSink: LocationEventSink?
    
    private let logger = Logger(subsystem: "com.life247", category: "LocationFilter")
    
    // MARK: - Public API
    
    /// Set the downstream event sink
    func setEventSink(_ sink: LocationEventSink) {
        self.eventSink = sink
    }
    
    /// Process a raw location update from LocationManager.
    /// Applies filtering and forwards to the event sink if accepted.
    func process(_ location: CLLocation, isHighAccuracyMode: Bool) {
        // 1. Staleness check
        let age = Date().timeIntervalSince(location.timestamp)
        if age > maxLocationAge {
            // Allow stale location only if we have no position at all (first launch)
            if filteredLocation != nil {
                logger.debug("Rejected stale location (age: \(String(format: "%.1f", age))s)")
                return
            }
        }
        
        // 2. Accuracy gating (relaxed in low-power mode for wake events)
        let accuracyLimit = isHighAccuracyMode ? maxAccuracy : 100.0
        if location.horizontalAccuracy > accuracyLimit || location.horizontalAccuracy < 0 {
            logger.debug("Rejected low-accuracy location (accuracy: \(String(format: "%.1f", location.horizontalAccuracy))m)")
            return
        }
        
        // 3. Jitter suppression when stationary
        if let lastLocation = filteredLocation {
            let isStationary = location.speed < stationarySpeedThreshold || location.speed < 0
            
            if isStationary {
                let distance = location.distance(from: lastLocation)
                let threshold = max(jitterThreshold, location.horizontalAccuracy)
                
                if distance < threshold {
                    // Movement is within noise range - suppress jitter
                    // Still update speed/course if meaningful, but keep position stable
                    logger.debug("Suppressed jitter (distance: \(String(format: "%.1f", distance))m < threshold: \(String(format: "%.1f", threshold))m)")
                    return
                }
            }
        }
        
        // Location accepted - update state and forward
        filteredLocation = location
        eventSink?.handle(.locationUpdate(location))
    }
    
    /// Forward non-location events directly (geofence, visits, etc.)
    func forward(_ event: DriveEvent) {
        eventSink?.handle(event)
    }
    
    /// Reset filter state
    func reset() {
        filteredLocation = nil
    }
}
