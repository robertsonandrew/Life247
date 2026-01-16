//
//  LocationInterpolator.swift
//  Life247
//
//  Created by Andrew Robertson on 1/15/26.
//

import Foundation
import CoreLocation
import QuartzCore

/// Smooths GPS samples into 60fps coordinate stream for MapKit binding.
/// Interpolates between GPS samples using time-based lerp.
@Observable
class LocationInterpolator {
    
    // MARK: - Published State
    
    /// Smoothed coordinate for map binding
    private(set) var displayCoordinate: CLLocationCoordinate2D?
    
    /// Smoothed heading for puck rotation
    private(set) var displayHeading: Double = 0
    
    /// Current speed from latest sample
    private(set) var displaySpeed: Double = 0
    
    // MARK: - Private State
    
    private var lastLocation: CLLocation?
    private var targetLocation: CLLocation?
    private var displayLink: CADisplayLink?
    private var isRunning: Bool = false
    
    // MARK: - Configuration
    
    /// Maximum gap before snapping (seconds)
    private let maxTimeGap: TimeInterval = 5.0
    
    /// Maximum distance jump before snapping (meters)
    private let maxDistanceJump: Double = 500.0
    
    /// Speed threshold for stop-state (m/s)
    private let stopSpeedThreshold: Double = 0.5
    
    /// Maximum drift before forced snap (meters)
    private let maxErrorTolerance: Double = 50.0
    
    // MARK: - Initialization
    
    init() {}
    
    deinit {
        stop()
    }
    
    // MARK: - Public API
    
    /// Receive a new GPS location sample
    func receive(_ location: CLLocation) {
        let shouldSnap = shouldReset(from: lastLocation, to: location)
        
        // Update target
        lastLocation = targetLocation ?? location
        targetLocation = location
        
        // Update speed and heading from real GPS
        displaySpeed = max(0, location.speed)
        if location.course >= 0 {
            displayHeading = location.course
        }
        
        // Snap or start interpolation
        if shouldSnap {
            displayCoordinate = location.coordinate
            lastLocation = location
        }
        
        // Only run display link when moving - stop when stationary to save CPU
        if location.speed >= stopSpeedThreshold {
            if !isRunning {
                startDisplayLink()
            }
        } else {
            // Stationary - update position directly and stop expensive animation loop
            displayCoordinate = location.coordinate
            if isRunning {
                stop()
            }
        }
    }
    
    /// Stop interpolation (call when tracking ends)
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        isRunning = false
    }
    
    /// Reset all state
    func reset() {
        stop()
        lastLocation = nil
        targetLocation = nil
        displayCoordinate = nil
        displayHeading = 0
        displaySpeed = 0
    }
    
    // MARK: - Private Methods
    
    private func shouldReset(from: CLLocation?, to: CLLocation) -> Bool {
        // First sample
        guard let from = from else { return true }
        
        // Time gap too large
        let gap = to.timestamp.timeIntervalSince(from.timestamp)
        if gap > maxTimeGap || gap < 0 {
            return true
        }
        
        // Distance jump too large (teleport)
        let distance = to.distance(from: from)
        if distance > maxDistanceJump {
            return true
        }
        
        return false
    }
    
    private func startDisplayLink() {
        guard !isRunning else { return }
        
        displayLink = CADisplayLink(target: self, selector: #selector(tick))
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        displayLink?.add(to: .main, forMode: .common)
        isRunning = true
    }
    
    @objc private func tick() {
        guard let last = lastLocation,
              let target = targetLocation else { return }
        
        // Stop-state: hold position when stopped (avoid GPS jitter)
        if target.speed < stopSpeedThreshold {
            displayCoordinate = target.coordinate
            return
        }
        
        // Calculate interpolation factor
        let now = Date()
        let elapsed = now.timeIntervalSince(last.timestamp)
        let interval = target.timestamp.timeIntervalSince(last.timestamp)
        
        // Avoid division by zero
        guard interval > 0 else {
            displayCoordinate = target.coordinate
            return
        }
        
        // Clamp t to [0, 1] — hold at target if we've arrived
        let t = min(max(elapsed / interval, 0), 1)
        
        // Lerp coordinates
        let lat = lerp(last.coordinate.latitude, target.coordinate.latitude, t)
        let lon = lerp(last.coordinate.longitude, target.coordinate.longitude, t)
        let interpolated = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        
        // Error tolerance check
        let error = distance(from: interpolated, to: target.coordinate)
        if error > maxErrorTolerance {
            // Snap to actual GPS if drift too large
            displayCoordinate = target.coordinate
        } else {
            displayCoordinate = interpolated
        }
    }
    
    // MARK: - Math Helpers
    
    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }
    
    private func distance(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let loc1 = CLLocation(latitude: from.latitude, longitude: from.longitude)
        let loc2 = CLLocation(latitude: to.latitude, longitude: to.longitude)
        return loc1.distance(from: loc2)
    }
}
