//
//  LocationBufferManager.swift
//  Life247
//
//  Created by Andrew Robertson on 1/24/26.
//

import Foundation
import CoreLocation
import OSLog

/// Manages a circular buffer of location points captured during the `maybeDriving` state.
/// This ensures drives start at the actual departure point (e.g., saved place) rather than
/// where driving speed was confirmed.
///
/// Thread Safety: This class is designed for use on the MainActor only.
@MainActor
final class LocationBufferManager {
    
    // MARK: - Configuration
    
    /// Maximum number of locations to buffer (~30 seconds at 1 Hz)
    private let maxBufferSize: Int
    
    /// Minimum horizontal accuracy to accept a point (meters)
    private let minAccuracy: Double
    
    // MARK: - State
    
    private var buffer: [CLLocation] = []
    private let logger = Logger(subsystem: "com.life247", category: "LocationBuffer")
    
    // MARK: - Initialization
    
    /// Initialize with configuration
    /// - Parameters:
    ///   - maxSize: Maximum buffer size (default: 30 points)
    ///   - minAccuracy: Minimum horizontal accuracy to accept points (default: 30m)
    init(maxSize: Int = 30, minAccuracy: Double = 30.0) {
        self.maxBufferSize = maxSize
        self.minAccuracy = minAccuracy
    }
    
    // MARK: - Public Interface
    
    /// Number of buffered locations
    var count: Int {
        buffer.count
    }
    
    /// Whether the buffer is empty
    var isEmpty: Bool {
        buffer.isEmpty
    }
    
    /// Add a location to the buffer if it passes quality filters.
    /// Maintains circular buffer behavior - oldest points are removed when full.
    /// - Parameter location: The location to buffer
    /// - Returns: True if the location was added, false if rejected
    @discardableResult
    func add(_ location: CLLocation) -> Bool {
        // Filter out low-accuracy readings
        guard location.horizontalAccuracy > 0,
              location.horizontalAccuracy <= minAccuracy else {
            return false
        }
        
        buffer.append(location)
        
        // Maintain circular buffer - remove oldest when over capacity
        while buffer.count > maxBufferSize {
            buffer.removeFirst()
        }
        
        logger.debug("[BUFFER] Captured location (\(self.buffer.count) points)")
        return true
    }
    
    /// Clear all buffered locations
    func clear() {
        guard !buffer.isEmpty else { return }
        let count = buffer.count
        buffer.removeAll()
        logger.debug("[BUFFER] Cleared \(count) points")
    }
    
    /// Consume and return all buffered locations, clearing the buffer.
    /// Use this when promoting buffered points to a new drive.
    /// - Returns: Array of buffered locations in chronological order
    func consumeAll() -> [CLLocation] {
        let locations = buffer
        buffer.removeAll()
        if !locations.isEmpty {
            logger.debug("[BUFFER] Consumed \(locations.count) points")
        }
        return locations
    }
    
    /// Get the first (oldest) buffered location without removing it
    var first: CLLocation? {
        buffer.first
    }
    
    /// Get the last (newest) buffered location without removing it
    var last: CLLocation? {
        buffer.last
    }
}
