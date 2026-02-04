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
/// Owns all puck state transitions with hysteresis to prevent visual flickering.
@Observable
class LocationInterpolator {
    
    // MARK: - Published State
    
    /// Smoothed coordinate for map binding
    private(set) var displayCoordinate: CLLocationCoordinate2D?
    
    /// Smoothed heading for puck rotation (GPS course when moving, compass when stopped)
    private(set) var displayHeading: Double = 0
    
    /// EMA-smoothed speed for UI display (m/s)
    private(set) var displaySpeed: Double = 0
    
    /// Current puck visual state (stopped = dot, moving = arrow)
    private(set) var puckState: PuckState = .stopped
    
    /// Counter that increments on each display update - use this for onChange observation
    /// (CLLocationCoordinate2D doesn't conform to Equatable, but Int does)
    private(set) var updateCounter: Int = 0
    
    // MARK: - Private State
    
    private var lastLocation: CLLocation?
    private var targetLocation: CLLocation?
    private var displayLink: CADisplayLink?
    private var isRunning: Bool = false
    
    /// Wall-clock time when the latest GPS sample arrived (for arrival-time interpolation)
    private var animationStartDate: Date?
    
    /// Puck position when the latest GPS sample arrived (lerp start point)
    private var animationStartCoordinate: CLLocationCoordinate2D?
    
    /// Heading when the latest GPS sample arrived (lerp start point)
    private var animationStartHeading: Double?
    
    /// Raw speed from GPS (unsmoothed) - used for state transitions only
    private var rawSpeed: Double = 0
    
    /// Timer for stopped-state hysteresis (must stay below threshold for duration)
    private var stoppedHysteresisStart: Date?
    
    /// Last valid compass heading (held when compass unavailable)
    private var lastCompassHeading: Double?
    
    /// Last valid GPS course (held when transitioning to stopped)
    private var lastValidCourse: Double = 0
    
    // MARK: - Configuration
    
    /// Maximum gap before snapping (seconds)
    private let maxTimeGap: TimeInterval = 5.0
    
    /// Maximum distance jump before snapping (meters)
    private let maxDistanceJump: Double = 500.0
    
    /// Maximum drift before forced snap (meters)
    private let maxErrorTolerance: Double = 50.0
    
    // MARK: - Puck State Hysteresis Thresholds
    
    /// Speed threshold to transition TO moving state (m/s) - ~3 mph, instant transition
    private let movingThreshold: Double = 1.34
    
    /// Speed threshold to transition TO stopped state (m/s) - ~0.5 mph
    private let stoppedThreshold: Double = 0.22
    
    /// Duration speed must stay below stoppedThreshold to confirm stopped (seconds)
    private let stoppedHysteresisDuration: TimeInterval = 2.0
    
    // MARK: - Speed & Heading Smoothing Configuration
    
    /// EMA alpha for display speed smoothing (0.2 = smooth, 0.5 = responsive)
    private let speedEMAlpha: Double = 0.25
    
    /// EMA alpha for heading smoothing (0.3 = balanced responsiveness/stability)
    private let headingEMAlpha: Double = 0.3
    
    /// EMA alpha for compass heading smoothing (reduces jitter when stationary)
    private let compassEMAlpha: Double = 0.3
    
    /// Minimum speed (m/s) to accept GPS course updates (~4.5 mph)
    private let minSpeedForCourse: Double = 2.0
    
    /// Maximum horizontal accuracy (meters) to trust course
    private let maxAccuracyForCourse: Double = 30.0
    
    /// Whether we have ever received a valid heading
    private var hasValidHeading: Bool = false
    
    // MARK: - Initialization
    
    init() {}
    
    deinit {
        stop()
    }
    
    // MARK: - Public API
    
    /// Maximum age for accepting a location (seconds) - matches DriveStateMachine threshold
    private let maxLocationAgeSeconds: TimeInterval = 12.0
    
    /// Receive a new GPS location sample
    func receive(_ location: CLLocation) {
        // Ignore stale cached locations (common on app launch/resume).
        // Logic:
        // 1. If we have NO position yet, accept anything (even stale) so the puck appears.
        // 2. If we HAVE a position, only accept FRESH locations to prevent jumping backward.
        let ageSeconds = Date().timeIntervalSince(location.timestamp)
        
        // Ignore stale locations - prefer fresh GPS data
        // Only exception: accept stale if we have NO position at all (first launch)
        if ageSeconds > maxLocationAgeSeconds {
            if displayCoordinate == nil {
                // Accept stale for initial position, but mark it so fresh data can override
            } else {
                return  // Already have a position, ignore stale update
            }
        }
        
        let shouldSnap = shouldReset(from: lastLocation, to: location)
        
        // Capture animation start state BEFORE updating targets
        // This is the key fix: we lerp from where the puck IS to where it SHOULD BE,
        // using wall-clock time rather than GPS timestamps.
        let now = Date()
        animationStartDate = now
        animationStartCoordinate = displayCoordinate ?? location.coordinate
        
        // Only reset heading animation start if course changed significantly (>15°)
        // This prevents spinning when GPS course data is noisy
        // Also ensures we have valid course data before comparing
        if location.course >= 0, location.speed >= minSpeedForCourse {
            if let lastCourse = targetLocation?.course, lastCourse >= 0 {
                let courseDelta = abs(shortestAngleDelta(from: lastCourse, to: location.course))
                if courseDelta > 15 {
                    // Significant turn - capture current display heading as animation start
                    animationStartHeading = displayHeading
                }
                // Otherwise keep existing animationStartHeading (don't reset)
            } else {
                // No previous course, start fresh
                animationStartHeading = displayHeading
            }
        }
        // If course is invalid or speed too low, don't update animationStartHeading at all
        
        // Update target
        lastLocation = targetLocation ?? location
        targetLocation = location
        
        // Update raw speed (for state transitions) and smoothed display speed (for UI)
        rawSpeed = max(0, location.speed)
        updateSmoothedSpeed(rawSpeed)
        
        // Update puck state with hysteresis
        updatePuckState()
        
        // Snap or start interpolation
        if shouldSnap {
            displayCoordinate = location.coordinate
            animationStartCoordinate = location.coordinate
            lastLocation = location
            // Also update heading immediately on snap
            if location.course >= 0 && location.speed >= minSpeedForCourse {
                displayHeading = location.course
                animationStartHeading = location.course
            }
        }
        
        // Only run display link when moving - stop when stationary to save CPU
        if rawSpeed >= stoppedThreshold {
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
    
    /// Receive compass heading update (from LocationManager)
    /// Used for puck orientation when stopped
    func receiveHeading(_ heading: CLHeading) {
        // Use trueHeading if available (corrected for magnetic declination), fallback to magnetic
        let rawHeading = heading.trueHeading >= 0 ? heading.trueHeading : heading.magneticHeading
        
        // Apply EMA smoothing to reduce compass jitter
        if let lastCompass = lastCompassHeading {
            let delta = shortestAngleDelta(from: lastCompass, to: rawHeading)
            let smoothed = lastCompass + compassEMAlpha * delta
            lastCompassHeading = normalizeAngle(smoothed)
        } else {
            lastCompassHeading = rawHeading
        }
        
        // Only apply to display heading when stopped
        if puckState == .stopped, let compassHeading = lastCompassHeading {
            displayHeading = compassHeading
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
        rawSpeed = 0
        puckState = .stopped
        stoppedHysteresisStart = nil
        lastCompassHeading = nil
        lastValidCourse = 0
        hasValidHeading = false
        animationStartDate = nil
        animationStartCoordinate = nil
        animationStartHeading = nil
        updateCounter = 0
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
              let target = targetLocation,
              let startDate = animationStartDate,
              let startCoord = animationStartCoordinate else { return }
        
        // Stop-state: hold position when stopped (avoid GPS jitter)
        if rawSpeed < stoppedThreshold {
            displayCoordinate = target.coordinate
            return
        }
        
        // Calculate interpolation factor using WALL-CLOCK time (arrival-time interpolation)
        // This is the key fix: we measure elapsed time since the location ARRIVED,
        // not since the GPS timestamp. This ensures t ramps 0→1 smoothly.
        let now = Date()
        let elapsed = now.timeIntervalSince(startDate)
        let interval = target.timestamp.timeIntervalSince(last.timestamp)
        
        // Avoid division by zero; use 1.0s default if timestamps are identical
        let duration = interval > 0 ? interval : 1.0
        
        // Clamp t to [0, 1] — hold at target if we've arrived
        let t = min(max(elapsed / duration, 0), 1)
        
        // Lerp coordinates from where puck WAS to where it SHOULD BE
        let lat = lerp(startCoord.latitude, target.coordinate.latitude, t)
        let lon = lerp(startCoord.longitude, target.coordinate.longitude, t)
        let interpolated = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        
        // Error tolerance check
        let error = distance(from: interpolated, to: target.coordinate)
        if error > maxErrorTolerance {
            // Snap to actual GPS if drift too large
            displayCoordinate = target.coordinate
        } else {
            displayCoordinate = interpolated
        }
        
        // Synchronized heading interpolation (lerp using same t factor)
        // Only interpolate when moving and we have valid course data
        if puckState == .moving,
           let startHeading = animationStartHeading,
           target.course >= 0,
           target.speed >= minSpeedForCourse,
           target.horizontalAccuracy > 0,
           target.horizontalAccuracy < maxAccuracyForCourse {
            // Use shortest-path angular interpolation
            let delta = shortestAngleDelta(from: startHeading, to: target.course)
            let lerpedHeading = startHeading + delta * t
            displayHeading = normalizeAngle(lerpedHeading)
        }
        
        // Increment counter so SwiftUI can observe changes (Int is Equatable)
        updateCounter &+= 1
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
    
    // MARK: - Puck State Hysteresis
    
    /// Update puck state with hysteresis to prevent visual flickering
    private func updatePuckState() {
        switch puckState {
        case .stopped:
            // Transition to MOVING: instant when speed exceeds threshold
            if rawSpeed >= movingThreshold {
                puckState = .moving
                stoppedHysteresisStart = nil
                // Preserve last course as initial heading for arrow
                if hasValidHeading {
                    lastValidCourse = displayHeading
                }
            }
            
        case .moving:
            // Transition to STOPPED: requires sustained low speed
            if rawSpeed < stoppedThreshold {
                // Start or continue hysteresis timer
                if stoppedHysteresisStart == nil {
                    stoppedHysteresisStart = Date()
                } else if let start = stoppedHysteresisStart,
                          Date().timeIntervalSince(start) >= stoppedHysteresisDuration {
                    // Timer elapsed - confirm stopped
                    puckState = .stopped
                    stoppedHysteresisStart = nil
                    // Switch to compass heading if available, otherwise hold last course
                    if let compassHeading = lastCompassHeading {
                        displayHeading = compassHeading
                    }
                    // else: keep displayHeading as last valid GPS course
                }
            } else {
                // Speed back above threshold - cancel hysteresis
                stoppedHysteresisStart = nil
            }
        }
    }
    
    // MARK: - Speed Smoothing
    
    /// Update display speed with EMA smoothing for stable UI
    private func updateSmoothedSpeed(_ newRawSpeed: Double) {
        if displaySpeed == 0 {
            // First value: snap directly
            displaySpeed = newRawSpeed
        } else {
            // EMA: displaySpeed = α * new + (1-α) * old
            displaySpeed = speedEMAlpha * newRawSpeed + (1 - speedEMAlpha) * displaySpeed
        }
    }
    
    // MARK: - Heading Smoothing
    
    /// Update heading with EMA smoothing and quality gates (GPS course for moving state)
    private func updateSmoothedHeading(rawCourse: Double, speed: Double, accuracy: Double) {
        // Gate 1: Reject invalid course (-1 means unavailable)
        guard rawCourse >= 0 else { return }
        
        // Gate 2: Require minimum speed to trust course
        // At low speeds, GPS course becomes unreliable/noisy
        guard speed >= minSpeedForCourse else { return }
        
        // Gate 3: Require decent horizontal accuracy
        guard accuracy > 0 && accuracy < maxAccuracyForCourse else { return }
        
        // Store as last valid course (for hold-on-stop behavior)
        lastValidCourse = rawCourse
        
        // First valid heading: snap directly
        if !hasValidHeading {
            displayHeading = rawCourse
            hasValidHeading = true
            return
        }
        
        // EMA smoothing with proper angle wraparound
        let delta = shortestAngleDelta(from: displayHeading, to: rawCourse)
        let smoothed = displayHeading + headingEMAlpha * delta
        displayHeading = normalizeAngle(smoothed)
    }
    
    /// Calculate shortest angular delta (handles 359° → 1° wraparound)
    private func shortestAngleDelta(from: Double, to: Double) -> Double {
        var delta = to - from
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }
        return delta
    }
    
    /// Normalize angle to [0, 360) range
    private func normalizeAngle(_ angle: Double) -> Double {
        var a = angle
        while a < 0 { a += 360 }
        while a >= 360 { a -= 360 }
        return a
    }
}
