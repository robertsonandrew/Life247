//
//  AccelerationDetector.swift
//  Life247
//
//  Created by Andrew Robertson on 1/19/26.
//

import Foundation
import CoreMotion
import CoreLocation
import OSLog

// MARK: - Coordinate System Documentation
/*
 ┌─────────────────────────────────────────────────────────────────────────────┐
 │                    G-FORCE DETECTION COORDINATE SYSTEM                       │
 ├─────────────────────────────────────────────────────────────────────────────┤
 │                                                                              │
 │  PROBLEM: Raw accelerometer data is in DEVICE frame, which changes based    │
 │  on how the phone is mounted (portrait, landscape, flat on dash, etc.)      │
 │                                                                              │
 │  SOLUTION: Transform device frame → world frame → vehicle frame             │
 │                                                                              │
 │  STEP 1: Device Frame (from CMDeviceMotion.userAcceleration)                │
 │  ─────────────────────────────────────────────────────────────              │
 │  • X: Right (in portrait mode)                                              │
 │  • Y: Up (top of phone)                                                     │
 │  • Z: Out of screen (toward user)                                           │
 │  • Units: m/s² (gravity already removed via sensor fusion)                  │
 │                                                                              │
 │  STEP 2: World Frame (via attitude.rotationMatrix)                          │
 │  ─────────────────────────────────────────────────────                      │
 │  Using CMAttitudeReferenceFrameXMagneticNorthZVertical:                     │
 │  • X: Magnetic North                                                        │
 │  • Y: West                                                                  │
 │  • Z: Up (away from Earth's center)                                         │
 │                                                                              │
 │  Transform: a_world = R^T × a_device                                        │
 │  (R^T is transpose of rotationMatrix, since R goes world→device)            │
 │                                                                              │
 │  STEP 3: Vehicle Frame (via GPS heading)                                    │
 │  ────────────────────────────────────────                                   │
 │  • Longitudinal: Forward/backward (+ = acceleration, − = braking)           │
 │  • Lateral: Left/right (+ = right turn, − = left turn)                      │
 │  • Vertical: Up/down (ignored for driving events)                           │
 │                                                                              │
 │  Transform using heading θ (degrees clockwise from North):                  │
 │    longitudinal = a_north × cos(θ) + a_east × sin(θ)                        │
 │    lateral = −a_north × sin(θ) + a_east × cos(θ)                            │
 │                                                                              │
 │  WHY THIS WORKS:                                                            │
 │  ───────────────                                                            │
 │  • Phone orientation doesn't matter - rotation matrix handles it            │
 │  • Vehicle direction comes from GPS course, not phone orientation           │
 │  • Braking always shows negative longitudinal, regardless of phone mount    │
 │  • Right turns always show positive lateral, regardless of phone mount      │
 │                                                                              │
 └─────────────────────────────────────────────────────────────────────────────┘
*/

// MARK: - Configuration

/// Thresholds and configuration for acceleration event detection
struct AccelerationDetectorConfig {
    /// Minimum G-force for hard braking detection (negative longitudinal)
    /// TESTING: Lowered to 0.10 (very light braking) - restore to 0.25 for production
    var hardBrakeThresholdG: Double = 0.10
    
    /// Minimum G-force for hard acceleration detection (positive longitudinal)
    /// TESTING: Lowered to 0.10 (very light acceleration) - restore to 0.20 for production
    var hardAccelThresholdG: Double = 0.10
    
    /// Minimum G-force for hard cornering detection (lateral)
    /// TESTING: Lowered to 0.10 (very normal turns) - restore to 0.30 for production
    var hardCornerThresholdG: Double = 0.10
    
    /// Sample rate for accelerometer (Hz). 25 Hz is good balance of accuracy vs battery.
    var sampleRateHz: Double = 25.0
    
    /// Minimum duration (seconds) above threshold to register as event (debounce)
    /// TESTING: Lowered to 0.10s - restore to 0.3 for production
    var minimumEventDuration: TimeInterval = 0.10
    
    /// Cooldown between same-type events (seconds) to prevent duplicates
    var eventCooldown: TimeInterval = 2.0
    
    /// Minimum GPS speed (m/s) to enable detection. Below this, too many false positives.
    /// TESTING: Lowered to 2.0 (~4.5 mph) - restore to 5.0 for production
    var minimumGPSSpeed: Double = 2.0  // ~4.5 mph
    
    /// GPS corroboration: minimum speed delta (m/s) expected for braking event
    var gpsCorroborationDelta: Double = 2.0  // ~4.5 mph change
    
    /// Whether to require GPS corroboration (stricter, fewer false positives)
    var requireGPSCorroboration: Bool = false
    
    /// Smoothing factor for exponential moving average (0-1, lower = more smoothing)
    var smoothingAlpha: Double = 0.3
    
    /// Enable verbose debug logging
    var debugLogging: Bool = true
    
    static let `default` = AccelerationDetectorConfig()
}

// MARK: - Detected Event DTO

/// Thread-safe struct for passing event data across concurrency boundaries.
/// This decouples the detector from SwiftData models.
struct DetectedAccelerationEvent: Sendable {
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let eventType: AccelerationEventType
    let gForceMagnitude: Double
    let longitudinalG: Double
    let lateralG: Double
    let gpsSpeed: Double
    let gpsSpeedDelta: Double?
    let gpsCorroborated: Bool
    let durationSeconds: Double?
    let heading: Double
}

// MARK: - Detector State

/// Internal state for tracking ongoing events
private struct PendingEvent {
    let type: AccelerationEventType
    let startTime: Date
    var peakG: Double
    var peakLongitudinalG: Double
    var peakLateralG: Double
    var startLocation: CLLocation?
    var startSpeed: Double
    var lastSampleTime: Date
    var sampleCount: Int
}

// MARK: - Acceleration Detector

/// Detects significant acceleration events (braking, acceleration, cornering) during driving.
///
/// This class handles:
/// 1. Coordinate transformation from device frame to vehicle frame
/// 2. Event detection with configurable thresholds
/// 3. Debouncing to produce one event per maneuver
/// 4. GPS corroboration to filter false positives
///
/// Thread Safety:
/// All public methods are thread-safe. Motion samples arrive on a background queue while
/// GPS updates and start/stop calls come from the main thread. Internal state is protected
/// by a serial dispatch queue.
///
/// Usage:
/// ```swift
/// let detector = AccelerationDetector()
/// detector.onEventDetected = { event in
///     // Save to SwiftData, associate with drive
/// }
/// detector.start()
/// // Call processMotion() on each CMDeviceMotion sample
/// // Call updateGPS() on each CLLocation update
/// detector.stop()
/// ```
final class AccelerationDetector {
    
    // MARK: - Properties
    
    var config: AccelerationDetectorConfig
    
    /// Callback when an event is detected. Emits a thread-safe struct.
    /// Called on the internal queue; dispatch to main if needed for UI updates.
    var onEventDetected: ((DetectedAccelerationEvent) -> Void)?
    
    private let logger = Logger(subsystem: "com.life247", category: "AccelerationDetector")
    
    /// Serial queue protecting all mutable state. All state reads/writes must occur on this queue.
    private let stateQueue = DispatchQueue(label: "com.life247.accelerationDetector", qos: .userInitiated)
    
    // Debug logging state (protected by stateQueue)
    private var sampleCount: Int = 0
    private var lastDebugLogTime: Date = .distantPast
    
    // State (protected by stateQueue)
    private var isRunning = false
    private var lastGPSLocation: CLLocation?
    private var previousGPSLocation: CLLocation?
    /// Heading in degrees from North (0-360). -1 means unknown.
    private var lastHeading: Double = -1
    
    // Smoothed acceleration values (EMA) (protected by stateQueue)
    private var smoothedLongitudinalG: Double = 0
    private var smoothedLateralG: Double = 0
    
    // Pending events (for debouncing) (protected by stateQueue)
    private var pendingEvents: [AccelerationEventType: PendingEvent] = [:]
    
    // Cooldown tracking (protected by stateQueue)
    private var lastEventTime: [AccelerationEventType: Date] = [:]
    
    // Constants
    private let gravity: Double = 9.81  // m/s²
    
    // MARK: - Initialization
    
    init(config: AccelerationDetectorConfig = .default) {
        self.config = config
    }
    
    // MARK: - Control
    
    func start() {
        stateQueue.async { [self] in
            guard !isRunning else { return }
            isRunning = true
            resetInternal()
            logger.info("AccelerationDetector started")
        }
    }
    
    func stop() {
        stateQueue.async { [self] in
            guard isRunning else { return }
            
            // Finalize any pending events
            finalizePendingEvents()
            
            isRunning = false
            logger.info("AccelerationDetector stopped")
        }
    }
    
    func reset() {
        stateQueue.async { [self] in
            resetInternal()
        }
    }
    
    /// Internal reset, must be called on stateQueue
    private func resetInternal() {
        smoothedLongitudinalG = 0
        smoothedLateralG = 0
        pendingEvents.removeAll()
        lastEventTime.removeAll()
        lastGPSLocation = nil
        previousGPSLocation = nil
        lastHeading = -1
    }
    
    // MARK: - GPS Updates
    
    /// Update with latest GPS location. Call on each CLLocation update.
    func updateGPS(_ location: CLLocation) {
        stateQueue.async { [self] in
            previousGPSLocation = lastGPSLocation
            lastGPSLocation = location
            
            // Update heading if valid
            if location.course >= 0 {
                lastHeading = location.course
            } else if let prev = previousGPSLocation {
                // CLLocation.course is often -1 in low-power/background regimes.
                // Fall back to bearing from consecutive GPS points.
                lastHeading = bearingDegrees(from: prev, to: location)
            }
        }
    }

    // MARK: - Helpers

    /// CLLocation.speed is often -1 in low-power/background regimes. Use a fallback derived from GPS deltas.
    private func effectiveSpeedMS(for location: CLLocation) -> Double {
        if location.speed >= 0 {
            return location.speed
        }
        guard let prev = previousGPSLocation else { return 0 }
        let dt = location.timestamp.timeIntervalSince(prev.timestamp)
        guard dt > 0 else { return 0 }
        let meters = location.distance(from: prev)
        let speed = meters / dt
        // Clamp to avoid extreme spikes from poor fixes.
        return min(max(speed, 0), 70) // ~156 mph
    }

    /// Initial bearing from one coordinate to another, in degrees [0, 360).
    private func bearingDegrees(from: CLLocation, to: CLLocation) -> Double {
        let lat1 = from.coordinate.latitude * .pi / 180
        let lon1 = from.coordinate.longitude * .pi / 180
        let lat2 = to.coordinate.latitude * .pi / 180
        let lon2 = to.coordinate.longitude * .pi / 180

        let dLon = lon2 - lon1
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let radians = atan2(y, x)
        let degrees = radians * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }
    
    // MARK: - Motion Processing
    
    /// Process a device motion sample. Call on each CMDeviceMotion update (25-50 Hz).
    func processMotion(_ motion: CMDeviceMotion) {
        stateQueue.async { [self] in
            processMotionInternal(motion)
        }
    }
    
    /// Internal motion processing, must be called on stateQueue
    private func processMotionInternal(_ motion: CMDeviceMotion) {
        sampleCount += 1
        
        guard isRunning else {
            if config.debugLogging && sampleCount % 50 == 0 {
                logger.warning("[GFORCE-DEBUG] ❌ Detector not running, ignoring samples")
            }
            return
        }
        
        guard let gps = lastGPSLocation else {
            if config.debugLogging && sampleCount % 50 == 0 {
                logger.warning("[GFORCE-DEBUG] ❌ No GPS location available - call updateGPS()")
            }
            return
        }
        
        // Skip if moving too slowly (too many false positives from bumps)
        let speedMS = effectiveSpeedMS(for: gps)
        let speedMPH = speedMS * 2.23694
        guard speedMS >= config.minimumGPSSpeed else {
            if config.debugLogging && sampleCount % 50 == 0 {
                logger.debug("[GFORCE-DEBUG] ⏸️ Speed too low: \(String(format: "%.1f", speedMPH)) mph (min: \(String(format: "%.1f", self.config.minimumGPSSpeed * 2.23694)) mph)")
            }
            return
        }
        
        // Skip if heading is invalid
        guard lastHeading >= 0 else {
            if config.debugLogging && sampleCount % 50 == 0 {
                logger.warning("[GFORCE-DEBUG] ❌ Invalid heading: \(self.lastHeading)")
            }
            return
        }
        
        // STEP 1: Get acceleration in device frame (m/s², gravity removed)
        let ax_device = motion.userAcceleration.x
        let ay_device = motion.userAcceleration.y
        let az_device = motion.userAcceleration.z
        
        // STEP 2: Transform device frame → world frame using rotation matrix
        // The rotation matrix R from CMAttitude transforms world→device
        // So we use R^T (transpose) to go device→world
        let r = motion.attitude.rotationMatrix
        
        // a_world = R^T × a_device (transposed multiplication)
        let ax_world = r.m11 * ax_device + r.m21 * ay_device + r.m31 * az_device  // North
        let ay_world = r.m12 * ax_device + r.m22 * ay_device + r.m32 * az_device  // West
        // az_world would be vertical - we don't need it
        
        // Convert West to East (flip sign)
        let a_north = ax_world
        let a_east = -ay_world
        
        // STEP 3: Transform world frame → vehicle frame using GPS heading
        // heading is degrees clockwise from North
        let headingRad = lastHeading * .pi / 180.0
        
        // Longitudinal: positive = forward acceleration, negative = braking
        let longitudinal_ms2 = a_north * cos(headingRad) + a_east * sin(headingRad)
        
        // Lateral: positive = rightward acceleration (right turn), negative = left turn
        let lateral_ms2 = -a_north * sin(headingRad) + a_east * cos(headingRad)
        
        // Convert to G-force
        let longitudinalG = longitudinal_ms2 / gravity
        let lateralG = lateral_ms2 / gravity
        
        // Apply exponential moving average for smoothing
        smoothedLongitudinalG = config.smoothingAlpha * longitudinalG + (1 - config.smoothingAlpha) * smoothedLongitudinalG
        smoothedLateralG = config.smoothingAlpha * lateralG + (1 - config.smoothingAlpha) * smoothedLateralG
        
        // Debug logging every 2 seconds
        let now = Date()
        if config.debugLogging && now.timeIntervalSince(lastDebugLogTime) >= 2.0 {
            lastDebugLogTime = now
            let absLong = abs(self.smoothedLongitudinalG)
            let absLat = abs(self.smoothedLateralG)
            logger.info("[GFORCE-DEBUG] longG=\(String(format: "%.3f", self.smoothedLongitudinalG)) latG=\(String(format: "%.3f", self.smoothedLateralG)) | thresholds: brake=\(String(format: "%.2f", self.config.hardBrakeThresholdG)) accel=\(String(format: "%.2f", self.config.hardAccelThresholdG)) corner=\(String(format: "%.2f", self.config.hardCornerThresholdG))")
            
            // Log if we're close to thresholds
            if absLong > config.hardBrakeThresholdG * 0.5 || absLat > config.hardCornerThresholdG * 0.5 {
                logger.info("[GFORCE-DEBUG] ⚠️ Near threshold! longG=\(String(format: "%.3f", self.smoothedLongitudinalG)) latG=\(String(format: "%.3f", self.smoothedLateralG))")
            }
        }
        
        // Detect events
        detectEvents(
            longitudinalG: smoothedLongitudinalG,
            lateralG: smoothedLateralG,
            timestamp: Date(),
            location: gps
        )
    }
    
    // MARK: - Event Detection
    
    private func detectEvents(longitudinalG: Double, lateralG: Double, timestamp: Date, location: CLLocation) {
        // Check for hard braking (negative longitudinal exceeds threshold)
        if -longitudinalG >= config.hardBrakeThresholdG {
            handleThresholdExceeded(
                type: .hardBrake,
                g: abs(longitudinalG),
                longitudinalG: longitudinalG,
                lateralG: lateralG,
                timestamp: timestamp,
                location: location
            )
        } else {
            handleThresholdCleared(type: .hardBrake, timestamp: timestamp)
        }
        
        // Check for hard acceleration (positive longitudinal exceeds threshold)
        if longitudinalG >= config.hardAccelThresholdG {
            handleThresholdExceeded(
                type: .hardAcceleration,
                g: longitudinalG,
                longitudinalG: longitudinalG,
                lateralG: lateralG,
                timestamp: timestamp,
                location: location
            )
        } else {
            handleThresholdCleared(type: .hardAcceleration, timestamp: timestamp)
        }
        
        // Check for hard cornering left (negative lateral exceeds threshold)
        if -lateralG >= config.hardCornerThresholdG {
            handleThresholdExceeded(
                type: .hardCornerLeft,
                g: abs(lateralG),
                longitudinalG: longitudinalG,
                lateralG: lateralG,
                timestamp: timestamp,
                location: location
            )
        } else {
            handleThresholdCleared(type: .hardCornerLeft, timestamp: timestamp)
        }
        
        // Check for hard cornering right (positive lateral exceeds threshold)
        if lateralG >= config.hardCornerThresholdG {
            handleThresholdExceeded(
                type: .hardCornerRight,
                g: lateralG,
                longitudinalG: longitudinalG,
                lateralG: lateralG,
                timestamp: timestamp,
                location: location
            )
        } else {
            handleThresholdCleared(type: .hardCornerRight, timestamp: timestamp)
        }
    }
    
    private func handleThresholdExceeded(
        type: AccelerationEventType,
        g: Double,
        longitudinalG: Double,
        lateralG: Double,
        timestamp: Date,
        location: CLLocation
    ) {
        // Check cooldown
        if let lastTime = lastEventTime[type],
           timestamp.timeIntervalSince(lastTime) < config.eventCooldown {
            return
        }
        
        if var pending = pendingEvents[type] {
            // Update existing pending event with peak values
            pending.peakG = max(pending.peakG, g)
            if abs(longitudinalG) > abs(pending.peakLongitudinalG) {
                pending.peakLongitudinalG = longitudinalG
            }
            if abs(lateralG) > abs(pending.peakLateralG) {
                pending.peakLateralG = lateralG
            }
            pending.lastSampleTime = timestamp
            pending.sampleCount += 1
            pendingEvents[type] = pending
        } else {
            // Start new pending event
            pendingEvents[type] = PendingEvent(
                type: type,
                startTime: timestamp,
                peakG: g,
                peakLongitudinalG: longitudinalG,
                peakLateralG: lateralG,
                startLocation: location,
                startSpeed: effectiveSpeedMS(for: location),
                lastSampleTime: timestamp,
                sampleCount: 1
            )
        }
    }
    
    private func handleThresholdCleared(type: AccelerationEventType, timestamp: Date) {
        guard let pending = pendingEvents[type] else { return }
        
        let duration = timestamp.timeIntervalSince(pending.startTime)
        
        // Check minimum duration (debounce)
        if duration >= config.minimumEventDuration {
            finalizeEvent(pending, endTime: timestamp)
        }
        
        pendingEvents.removeValue(forKey: type)
    }
    
    private func finalizePendingEvents() {
        let now = Date()
        for (_, pending) in pendingEvents {
            let duration = now.timeIntervalSince(pending.startTime)
            if duration >= config.minimumEventDuration {
                finalizeEvent(pending, endTime: now)
            }
        }
        pendingEvents.removeAll()
    }
    
    private func finalizeEvent(_ pending: PendingEvent, endTime: Date) {
        guard let location = pending.startLocation ?? lastGPSLocation else {
            logger.warning("Cannot finalize event - no location")
            return
        }
        
        let duration = endTime.timeIntervalSince(pending.startTime)
        
        // Calculate GPS speed delta for corroboration
        var speedDelta: Double? = nil
        var gpsCorroborated = false
        
        if let currentGPS = lastGPSLocation, let _ = previousGPSLocation {
            let currentSpeed = effectiveSpeedMS(for: currentGPS)
            speedDelta = currentSpeed - pending.startSpeed
            
            // Corroborate based on event type
            switch pending.type {
            case .hardBrake:
                // Braking should show decreasing speed
                gpsCorroborated = (speedDelta ?? 0) <= -config.gpsCorroborationDelta
            case .hardAcceleration:
                // Acceleration should show increasing speed
                gpsCorroborated = (speedDelta ?? 0) >= config.gpsCorroborationDelta
            case .hardCornerLeft, .hardCornerRight:
                // Cornering is harder to corroborate via GPS, always mark as corroborated
                // (could use heading change in future)
                gpsCorroborated = true
            }
        }
        
        // If requiring corroboration and not corroborated, skip
        if config.requireGPSCorroboration && !gpsCorroborated {
            logger.debug("Event \(pending.type.rawValue) not GPS-corroborated, skipping")
            return
        }
        
        // Create thread-safe event struct (not the SwiftData model)
        let event = DetectedAccelerationEvent(
            timestamp: pending.startTime,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            eventType: pending.type,
            gForceMagnitude: pending.peakG,
            longitudinalG: pending.peakLongitudinalG,
            lateralG: pending.peakLateralG,
            gpsSpeed: pending.startSpeed,
            gpsSpeedDelta: speedDelta,
            gpsCorroborated: gpsCorroborated,
            durationSeconds: duration,
            heading: lastHeading
        )
        
        // Update cooldown
        lastEventTime[pending.type] = endTime
        
        logger.info("Detected \(pending.type.displayName): \(String(format: "%.2f", pending.peakG))g, duration: \(String(format: "%.1f", duration))s, GPS corroborated: \(gpsCorroborated)")
        
        // Notify
        onEventDetected?(event)
    }
}
