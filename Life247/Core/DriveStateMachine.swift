//
//  DriveStateMachine.swift
//  Life247
//
//  Created by Andrew Robertson on 1/14/26.
//

import Foundation
import CoreLocation
import CoreMotion
import SwiftData
import OSLog
import UIKit

/// The single source of truth for drive state.
/// Only this class may start, stop, pause, or end a drive.
@MainActor
@Observable
final class DriveStateMachine {
    
    // MARK: - Debug Logging
    
    /// Enable verbose logging when attached to Xcode debugger
    #if DEBUG
    private let verboseLogging = true
    #else
    private let verboseLogging = false
    #endif
    
    // MARK: - Constants (Tuneable Parameters)
    
    /// Speed threshold to trigger maybeDriving (mph)
    private let maybeDrivingSpeedThreshold: Double = 5.0
    
    /// Speed threshold to confirm driving (mph)
    private let drivingConfirmationSpeed: Double = 10.0

    /// Guard against stale/bogus initial location speeds on app open.
    /// Require speed ≥ maybeDrivingSpeedThreshold for a short window before entering maybeDriving.
    private let idleSpeedConfirmSeconds: TimeInterval = 2.0
    /// Ignore location samples older than this for start decisions (seconds).
    private let idleStartLocationMaxAgeSeconds: TimeInterval = 12.0
    
    /// Speed threshold to detect stopped (mph)
    private let stoppedSpeedThreshold: Double = 1.0
    
    /// Speed threshold to resume from stopped (mph)
    private let resumeSpeedThreshold: Double = 5.0

    /// Minimum speed to resume when recent on-foot evidence exists (mph).
    /// Prevents walking/noise from bouncing stopped → driving.
    private let resumeSpeedThresholdOnFootRecent: Double = 8.0

    /// Sustained speed required before resuming from stopped (seconds).
    private let stoppedResumeSustainDuration: TimeInterval = 6.0

    /// Speed threshold to treat geofence entry as immediate arrival (mph)
    private let geofenceImmediateEndSpeedMPH: Double = 15.0

    /// Low-speed threshold to qualify a stop candidate (mph)
    private let lowSpeedCandidateThreshold: Double = 3.0

    /// Sustained low-speed duration to qualify a stop candidate (seconds)
    private let lowSpeedSustainForCandidate: TimeInterval = 20.0

    /// Recent travel window used to detect low-distance movement (seconds)
    private let stopDistanceWindow: TimeInterval = 60.0

    /// Max distance traveled within stop window to be considered stopped (meters)
    private let stopDistanceMaxMeters: Double = 30.0

    /// On-foot recency window (seconds)
    private let onFootRecentWindow: TimeInterval = 90.0

    /// Early auto-end delay when on-foot is recent (seconds)
    private let onFootEarlyEndDelay: TimeInterval = 90.0
    
    /// Maximum drive duration before safety end (hours)
    private let safetyMaxDriveHours: Double = 8.0
    
    /// Minimum horizontal accuracy for valid GPS readings (meters).
    /// References Drive.maxAccuracy for consistency.
    private var minAccuracy: Double { Drive.maxAccuracy }
    
    // MARK: - User-Adjustable Settings (Clamped)
    
    /// Settings struct - read lazily, never cached at init
    private var settings = DriveDetectionSettings()
    
    /// Duration required to confirm driving (seconds) - clamped
    private var drivingConfirmationDuration: TimeInterval {
        max(5, min(settings.drivingConfirmationDuration, 30))
    }
    
    /// Duration at low speed to enter stopped state (seconds) - clamped
    private var stoppedDetectionDuration: TimeInterval {
        max(10, min(settings.stoppedDetectionDuration, 120))
    }
    
    /// Maximum time in stopped before ending drive (minutes) - clamped
    private var stoppedTimeoutMinutes: Double {
        max(1, min(Double(settings.stoppedTimeoutMinutes), 15))
    }
    
    /// Centralized stopped timeout in seconds (use this instead of stoppedTimeoutMinutes * 60)
    private var stoppedTimeoutSeconds: TimeInterval {
        stoppedTimeoutMinutes * 60
    }

    /// Max age for a location used to confirm arrival (seconds)
    private let pendingArrivalMaxLocationAgeSeconds: TimeInterval = 120.0
    
    /// Maximum time in maybeDriving before giving up (seconds) - clamped
    private var verificationTimeout: TimeInterval {
        max(15, min(settings.verificationTimeout, 120))
    }
    
    // MARK: - Published State
    
    /// Current drive state
    private(set) var state: DriveState = .idle
    
    /// Current active drive (nil when idle or maybeDriving)
    private(set) var activeDrive: Drive?
    
    /// Latest location for UI display
    private(set) var currentLocation: CLLocation?
    
    /// Whether we're in post-drive monitoring grace period (high-accuracy still active).
    /// This helps recover if a drive ended due to a false arrival.
    private(set) var isPostDriveMonitoring: Bool = false
    
    /// Meters per second to miles per hour conversion factor
    private let msToMPH: Double = 2.23694
    
    /// Current speed in MPH (uses fallback calculation if CLLocation.speed is invalid)
    var currentSpeedMPH: Double {
        guard let location = currentLocation else { return 0 }
        return speedInMPH(for: location)
    }
    
    /// Compute speed in MPH for a location, using fallback calculation if CLLocation.speed is invalid
    private func speedInMPH(for location: CLLocation) -> Double {
        computeSpeed(for: location) * msToMPH
    }
    
    /// Maximum reasonable speed for fallback calculation (m/s) - ~100 mph
    private let maxFallbackSpeed: Double = 44.7
    
    // MARK: - Private State
    
    private var modelContext: ModelContext?
    private let logger = Logger(subsystem: "com.life247", category: "StateMachine")
    private let driveLogger = DriveLogger()
    private let traceLoggingEnabled = true

    // MARK: - Dwell / Place Visits
    
    /// Place visit manager handles all PlaceVisit lifecycle
    private let placeVisitManager = PlaceVisitManager()
    
    /// Current active dwell session (if any), suitable for lightweight UI.
    /// Delegates to PlaceVisitManager.
    var activeDwellSummary: PlaceVisitManager.ActiveDwellSummary? {
        placeVisitManager.activeDwellSummary
    }
    
    // Timer management
    private var verificationTimer: Task<Void, Never>?
    private var stoppedTimer: Task<Void, Never>?
    private var safetyTimer: Task<Void, Never>?
    private var pendingArrivalTimer: Task<Void, Never>?
    private var postDriveMonitoringDeadline: Date?
    
    /// Grace period after drive ends to keep high-accuracy mode active (seconds).
    /// This helps detect continued driving if the drive ended due to a false arrival.
    private let postDriveMonitoringDurationForeground: TimeInterval = 90.0
    private let postDriveMonitoringDurationBackground: TimeInterval = 20.0
    
    // Speed verification tracking
    private var sustainedHighSpeedStart: Date?
    private var sustainedLowSpeedStart: Date?

    // Idle → maybeDriving debouncer (prevents one-sample spikes from causing Detecting…)
    private var idleHighSpeedStart: Date?
    
    // Track the reason for the upcoming drive start
    private var pendingStartReason: DriveStartReason?
    
    // Track the reason for the upcoming drive end (defaults to inactivityTimeout if not set)
    private var pendingEndReason: DriveEndReason?
    
    // Last processed location for speed fallback calculation
    private var lastProcessedLocation: CLLocation?
    
    // High-confidence motion tracking for fast-track start
    private var hasHighConfidenceMotion: Bool = false
    
    // Recent automotive motion - lowers speed threshold for maybeDriving entry
    // Motion alone does NOT trigger maybeDriving; it requires GPS corroboration
    private var hasRecentAutomotiveMotion: Bool = false
    
    // Stopped state tracking (for Issue #1 fix)
    private var stoppedSince: Date?
    private var stoppedResumeCandidateStart: Date?

    // On-foot tracking for stop candidate logic
    private var lastOnFootAt: Date?

    // Low-speed candidate tracking (distinct from full stop detection)
    private var lowSpeedCandidateStart: Date?

    // Recent locations buffer for distance-based stop detection
    private var recentLocations: [CLLocation] = []
    
    // Track which geofence regions we're currently inside (for arrival detection)
    private var insideRegionIds: Set<String> = []
    
    // Periodic save tracking (for Issue #2 fix)
    private var pointsSinceLastSave: Int = 0
    private let saveInterval: Int = 50  // Save every 50 points
    
    // First location fix tracking for inspector
    private var hasRecordedFirstFix: Bool = false
    
    // Location buffer for maybeDriving state (captures points before drive is confirmed)
    // This ensures routes start at the actual departure point (e.g., saved place) not where speed was confirmed
    private let locationBuffer = LocationBufferManager(maxSize: 30, minAccuracy: 30.0)
    
    // Motion manager for accelerometer control
    private weak var motionManager: MotionManager?
    
    // Location manager for one-shot GPS requests
    private weak var locationManager: LocationManager?
    
    // MARK: - One-Shot GPS Debounce
    
    /// Last time we requested a one-shot GPS fix
    private var lastOneShotRequest: Date?
    
    /// Minimum interval between one-shot requests (prevents GPS spam)
    private let oneShotDebounceInterval: TimeInterval = 30.0
    
    // MARK: - Initialization
    
    init() {
        logger.info("DriveStateMachine initialized in idle state")
    }
    
    /// Configure with SwiftData model context
    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
        placeVisitManager.configure(modelContext: modelContext)
        recoverState()
    }
    
    /// Set motion manager for accelerometer control
    func setMotionManager(_ manager: MotionManager) {
        self.motionManager = manager
        
        // Fix: If we recovered a driving state before MotionManager was injected,
        // we need to start the accelerometer now.
        if state == .driving {
            logger.info("[RECOVERY] Resuming accelerometer for recovered drive")
            manager.startAccelerometer()
        }
    }
    
    /// Set location manager for one-shot GPS requests
    func setLocationManager(_ manager: LocationManager) {
        self.locationManager = manager
    }
    
    // MARK: - One-Shot GPS Helpers
    
    /// Reset debounce when entering idle or when grace period expires.
    /// This allows fresh one-shot requests for the next departure.
    private func resetOneShotDebounce() {
        lastOneShotRequest = nil
    }
    
    /// Request a one-shot GPS fix if not recently requested (debounced).
    private func requestOneShotGPSIfNeeded(reason: String) {
        let now = Date()
        
        // Debounce check
        if let lastRequest = lastOneShotRequest,
           now.timeIntervalSince(lastRequest) < oneShotDebounceInterval {
            logger.debug("[ONE-SHOT] Debounce active (last: \(Int(now.timeIntervalSince(lastRequest)))s ago)")
            return
        }
        
        lastOneShotRequest = now
        logger.info("[ONE-SHOT] Requesting GPS for: \(reason)")
        locationManager?.requestOneShotLocation(reason: reason)
    }
    
    // MARK: - State Reconciliation
    
    /// Reconcile state after Airplane Mode is disabled.
    /// Uses normal stop/end logic to end stale drives.
    /// Called automatically when Airplane Mode transitions OFF.
    func reconcileAfterPause() {
        logger.info("[RECONCILE] Airplane Mode disabled - checking for stale drives")
        
        guard state == .driving || state == .stopped else {
            logger.info("[RECONCILE] Not in active drive state - no action needed")
            return
        }
        
        // Check if we should end the drive based on current conditions.
        // Use the same speed fallback logic as normal tracking; CLLocation.speed can be -1.
        let speedMPH: Double
        if let location = currentLocation {
            speedMPH = speedInMPH(for: location)
        } else {
            speedMPH = 0
        }
        
        // If speed is near zero, transition using normal logic
        if speedMPH < stoppedSpeedThreshold {
            logger.info("[RECONCILE] Speed is low (\(String(format: "%.1f", speedMPH))mph) - transitioning to stopped")
            
            if state == .driving {
                transition(to: .stopped, trigger: "reconcile_low_speed")
            }
            
            // Start the stopped timer which will end the drive after timeout
            // (Timer was already started by transition to .stopped)
            
            // If we're already in .stopped, check if we've been stopped long enough to end
            if state == .stopped {
                let stoppedDuration = stoppedSince.map { Date().timeIntervalSince($0) } ?? 0
                
                // End drive if we've been in stopped state longer than timeout
                if stoppedDuration > stoppedTimeoutSeconds {
                    logger.info("[RECONCILE] Stopped duration (\(Int(stoppedDuration))s) exceeds timeout - ending drive")
                    transition(to: .ended, trigger: "reconcile_stopped_timeout")
                } else {
                    logger.info("[RECONCILE] Stopped for \(Int(stoppedDuration))s, timeout is \(Int(self.stoppedTimeoutSeconds))s - continuing")
                }
            }
        } else {
            // Speed is high enough - resume normal tracking
            logger.info("[RECONCILE] Speed is sufficient (\(String(format: "%.1f", speedMPH))mph) - resuming tracking")
        }
    }
    
    /// Manual recovery for truly stuck drives (emergency use only).
    /// Use reconcileAfterPause() for normal recovery after Airplane Mode.
    func recoverFromStuckDrive() {
        guard state == .driving || state == .stopped else {
            logger.info("[RECOVER] Cannot recover - not in driving/stopped state")
            return
        }
        
        logger.warning("[RECOVER] Manual recovery triggered by user")
        pendingEndReason = .stuckRecovery
        transition(to: .ended)
    }
    

    
    // MARK: - App Lifecycle
    
    /// Handle app state changes (foreground/background)
    func handleAppStateChange(_ state: String) {
        logger.info("App state changed: \(state)")
        driveLogger.logAppStateChange(to: state)
        
        // Save drive data immediately when entering background to minimize loss on termination
        if state == "background" {
            saveActiveDriveIfNeeded()

            // Avoid sticky background GPS indicator after a drive has ended.
            // In background, post-drive grace cannot be relied on (app suspension),
            // so end it immediately if we're already in `.ended`.
            if self.state == .ended && isPostDriveMonitoring {
                endPostDriveMonitoring(trigger: "app_backgrounded")
            }
        } else if state == "active" {
            // Reconcile grace deadlines after returning from suspension.
            updatePostDriveMonitoringIfNeeded()
        }
    }
    
    /// Immediately save the active drive data to persistence.
    /// Call this when the app is about to be suspended/terminated.
    private func saveActiveDriveIfNeeded() {
        guard activeDrive != nil, let modelContext else { return }
        
        do {
            try modelContext.save()
            logger.info("[PERSIST] Saved active drive on background entry")
            pointsSinceLastSave = 0
        } catch {
            logger.error("[PERSIST] Failed to save on background: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Cold-Start Recovery
    
    /// Speed threshold for cold-start confirmation (m/s) - ~15 mph
    private let coldStartSpeedThreshold: Double = 6.7
    
    /// Maximum age for a "recent" pending drive to bias toward resume (5 minutes)
    private let pendingDriveRecentAge: TimeInterval = 300.0
    
    /// Recover drive state after app launch (cold start).
    ///
    /// This method handles two scenarios:
    /// 1. Fresh recovery: No pending drive, motion suggests driving → start new detection
    /// 2. Pending drive: recoverState() found an unended drive but couldn't definitively end it
    ///    → Use motion evidence to decide whether to resume or end
    ///
    /// Decision table for pending drive:
    /// - motion=false → End the drive (user is not driving)
    /// - motion=true → Resume the drive
    ///
    /// Decision table for fresh recovery:
    /// - motion=false → Stay idle
    /// - motion=true + speed≥threshold → Enter `driving` directly
    /// - motion=true + speed unknown → Enter `maybeDriving`
    func recoverFromColdStart(
        motionSuggestsDriving: Bool,
        lastLocation: CLLocation?
    ) {
        // Airplane Mode: suppress cold-start recovery
        guard !AirplaneModeManager.shared.isEnabled else {
            logger.info("[AIRPLANE] Cold-start recovery suppressed")
            endPendingRecoveryDriveIfNeeded(reason: .appTermination) // Clean up
            return
        }
        
        logger.info("[COLDSTART] Beginning recovery - motion=\(motionSuggestsDriving), hasLocation=\(lastLocation != nil), hasPendingDrive=\(self.pendingRecoveryDrive != nil)")
        
        // Update current location
        if let location = lastLocation {
            currentLocation = location
        }
        
        // --- Handle pending drive from recoverState() ---
        if let pendingDrive = pendingRecoveryDrive {
            let driveAge = Date().timeIntervalSince(pendingDrive.startTime)
            let isRecentDrive = driveAge < pendingDriveRecentAge
            let wasNotStopped = pendingDrive.stoppedSince == nil
            
            // Bias toward resuming: The drive was already confirmed (state was .driving).
            // Only end it if we have strong evidence the user stopped.
            // For a recent drive that wasn't stopped, assume app was killed mid-drive.
            let shouldResume = motionSuggestsDriving || (isRecentDrive && wasNotStopped)
            
            if shouldResume {
                // Resume the pending drive
                let reason = motionSuggestsDriving ? "motion_confirms" : "recent_active_drive"
                logger.info("[COLDSTART] Resuming drive \(pendingDrive.shortId) - \(reason) (age=\(String(format: "%.0f", driveAge))s, wasNotStopped=\(wasNotStopped))")
                resumePendingRecoveryDrive(pendingDrive)
            } else {
                // Drive was old or was already stopped with no motion evidence
                logger.info("[COLDSTART] Ending drive \(pendingDrive.shortId) - no motion, age=\(String(format: "%.0f", driveAge))s, stoppedSince=\(pendingDrive.stoppedSince?.description ?? "nil")")
                endPendingRecoveryDriveIfNeeded(reason: .inactivityTimeout)
            }
            return
        }
        
        // --- Fresh recovery (no pending drive) ---
        guard self.state == .idle else {
            logger.info("[COLDSTART] Skipping - already in state: \(self.state.rawValue)")
            return
        }
        
        // Decision: No motion evidence → no recovery
        guard motionSuggestsDriving else {
            logger.info("[RECOVERY] Motion does not suggest driving → staying idle")
            return
        }
        
        // Check speed if available and fresh; avoid false starts from stale or low speed
        let rawSpeed = lastLocation?.speed ?? -1
        let speedAgeSeconds = lastLocation.map { Date().timeIntervalSince($0.timestamp) } ?? .greatestFiniteMagnitude
        let speedIsFresh = speedAgeSeconds <= idleStartLocationMaxAgeSeconds
        let speedValid = rawSpeed >= 0 && speedIsFresh
        let speedMPH = speedValid ? rawSpeed * msToMPH : -1
        
        if speedValid && rawSpeed >= coldStartSpeedThreshold {
            // Motion + fresh high speed → go directly to driving
            logger.info("[RECOVERY] Motion=YES, Fresh speed=\(String(format: "%.1f", speedMPH))mph → entering DRIVING")
            pendingStartReason = .coldStartRecovery
            transitionDirectToDriving(trigger: "cold_start_high_speed")
        } else {
            // Motion suggests driving but speed is stale/low/unknown → stay IDLE and corroborate via one-shot GPS
            let speedLabel = speedValid ? String(format: "%.1f", speedMPH) : "unknown"
            logger.info("[RECOVERY] Motion=YES, Speed=\(speedLabel)mph (stale/low) → staying IDLE and requesting one-shot GPS")
            requestOneShotGPSIfNeeded(reason: "cold_start_motion")
            return
        }
    }
    
    /// Resume a pending recovery drive (called when motion confirms driving)
    private func resumePendingRecoveryDrive(_ drive: Drive) {
        guard let modelContext else {
            pendingRecoveryDrive = nil
            return
        }
        
        activeDrive = drive
        state = .driving
        pendingRecoveryDrive = nil
        
        // Restore stopped state if the drive was stopped
        if let stoppedSince = drive.stoppedSince {
            state = .stopped
            self.stoppedSince = stoppedSince
            // Restart timer for remaining time
            let elapsed = Date().timeIntervalSince(stoppedSince)
            let remaining = max(1, stoppedTimeoutSeconds - elapsed)
            stoppedTimer = Task {
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled else { return }
                handle(.timerExpired(.stoppedTimeout))
            }
            logger.info("[COLDSTART] Resumed in stopped state (remaining: \(Int(remaining))s)")
        } else {
            startSafetyTimer()
        }
        
        // Log for timeline consistency
        driveLogger.attach(to: drive, context: modelContext)
        driveLogger.logStateTransition(
            from: "recovered",
            to: state.rawValue,
            trigger: "motion_confirmed_recovery",
            metadata: stateSnapshotMetadata()
        )
    }
    
    /// End a pending recovery drive (called when motion does not confirm driving)
    private func endPendingRecoveryDriveIfNeeded(reason: DriveEndReason) {
        guard let drive = pendingRecoveryDrive, let modelContext else {
            pendingRecoveryDrive = nil
            return
        }
        
        logger.info("[COLDSTART] Ending pending drive \(drive.shortId) with reason: \(reason.rawValue)")
        drive.finalize(endReason: reason)
        
        do {
            try modelContext.save()
        } catch {
            logger.error("[COLDSTART] Failed to save ended drive: \(error.localizedDescription)")
        }
        
        pendingRecoveryDrive = nil
    }
    
    // MARK: - Event Handling (Single Entry Point)
    
    /// Process a drive event. This is the ONLY way to update state.
    func handle(_ event: DriveEvent) {
        // Airplane Mode: suppress all detection logic
        guard !AirplaneModeManager.shared.isEnabled else {
            // Still update current location for UI display
            if case .locationUpdate(let location) = event {
                currentLocation = location
            }
            logger.debug("[AIRPLANE] Detection suppressed")
            return
        }
        
        // Verbose logging when attached to Xcode
        if verboseLogging {
            switch event {
            case .locationUpdate(let location):
                let speedMPH = max(0, location.speed * msToMPH)  // Raw iOS speed for debugging
                logger.info("[LOC] state=\(self.state.rawValue) speed=\(String(format: "%.1f", speedMPH))mph accuracy=\(Int(location.horizontalAccuracy))m")
            case .motionAutomotive(let confidence):
                logger.info("[MOTION] automotive state=\(self.state.rawValue) confidence=\(confidence.rawValue)")
            case .motionNotAutomotive:
                logger.info("[MOTION] notAutomotive state=\(self.state.rawValue)")
            case .motionOnFoot:
                logger.info("[MOTION] onFoot state=\(self.state.rawValue)")
            case .timerExpired(let kind):
                logger.info("[TIMER] \(kind.rawValue) expired state=\(self.state.rawValue)")
            default:
                logger.info("[EVENT] \(String(describing: event)) state=\(self.state.rawValue)")
            }
        } else {
            logger.debug("Received event: \(String(describing: event)) in state: \(self.state.rawValue)")
        }
        
        switch event {
        case .motionAutomotive(let confidence):
            handleMotionAutomotive(confidence: confidence)
            
        case .motionNotAutomotive:
            handleMotionNotAutomotive()
            
        case .motionOnFoot:
            handleMotionOnFoot()
            
        case .locationUpdate(let location):
            handleLocationUpdate(location)
            
        case .significantLocationChange:
            handleSignificantLocationChange()
            
        case .visitArrival(let visit):
            handleVisitArrival(visit)
            
        case .visitDeparture(let visit):
            handleVisitDeparture(visit)
            
        case .geofenceExit(let regionId):
            handleGeofenceExit(regionId: regionId)
            
        case .geofenceEntry(let regionId):
            handleGeofenceEntry(regionId: regionId)
            
        case .timerExpired(let kind):
            handleTimerExpired(kind)
        }
    }
    
    // MARK: - Event Handlers
    
    /// Handle acceleration events from the detector (called from background thread via MainActor hop)
    func handleAccelerationEvent(_ detected: DetectedAccelerationEvent) {
        guard let drive = activeDrive, let context = modelContext else {
            logger.warning("[GFORCE] ⚠️ Ignoring acceleration event - no active drive or context")
            return
        }
        
        // Create the SwiftData model on the main actor
        let event = AccelerationEvent(
            timestamp: detected.timestamp,
            latitude: detected.latitude,
            longitude: detected.longitude,
            eventType: detected.eventType,
            gForceMagnitude: detected.gForceMagnitude,
            longitudinalG: detected.longitudinalG,
            lateralG: detected.lateralG,
            gpsSpeed: detected.gpsSpeed,
            gpsSpeedDelta: detected.gpsSpeedDelta,
            gpsCorroborated: detected.gpsCorroborated,
            durationSeconds: detected.durationSeconds,
            heading: detected.heading,
            drive: drive
        )
        
        context.insert(event)
        drive.accelerationEvents.append(event)
        
        logger.info("[GFORCE] ✅ RECORDED \(detected.eventType.displayName): \(String(format: "%.2f", detected.gForceMagnitude))g - Drive now has \(drive.accelerationEvents.count) events")
    }
    
    private func handleMotionAutomotive(confidence: CMMotionActivityConfidence) {
        // Track high-confidence for fast-track logic
        hasHighConfidenceMotion = (confidence == .high)
        
        // Log motion for timeline
        let confidenceStr: String
        switch confidence {
        case .low: confidenceStr = "low"
        case .medium: confidenceStr = "medium"
        case .high: confidenceStr = "high"
        @unknown default: confidenceStr = "unknown"
        }
        driveLogger.log(.motion, type: "motion_automotive", message: "Automotive motion detected (\(confidenceStr))")
        
        switch state {
        case .idle:
            // Motion alone does NOT trigger maybeDriving (prevents false starts from vibrations)
            // Instead, set flag to lower speed threshold in handleLocationUpdate
            if confidence == .high || confidence == .medium {
                hasRecentAutomotiveMotion = true
                pendingStartReason = .motionActivity
                logger.debug("[MOTION] Automotive detected - awaiting GPS corroboration")
                
                // Request one-shot GPS to bootstrap detection
                requestOneShotGPSIfNeeded(reason: "motion_automotive")
            }
            
        case .maybeDriving:
            // Update confidence tracking; fast-track check happens in handleLocationUpdate
            if confidence == .high {
                pendingStartReason = .motionActivity
            }
            
        case .driving, .stopped:
            // Motion supports current driving assessment but doesn't change state
            break
            
        case .ended:
            // Ignore - drive already finalized
            break
            
        case .pendingArrival:
            // Motion during verification supports the "false arrival" case (if speed increases)
            // But we let handleLocationUpdate handle the actual resume via speed check
            break
        }
    }
    
    private func handleMotionNotAutomotive() {
        // Clear motion flags when motion is non-automotive
        hasHighConfidenceMotion = false
        hasRecentAutomotiveMotion = false
        
        // Log motion for timeline
        driveLogger.log(.motion, type: "motion_not_automotive", message: "Non-automotive motion detected")
        
        switch state {
        case .maybeDriving:
            // Non-automotive motion negates maybeDriving
            transition(to: .idle, trigger: "motion_not_automotive")
            
        case .idle, .driving, .stopped, .ended, .pendingArrival:
            // Ignore - GPS is the authority during active driving
            break
        }
    }
    
    private func handleMotionOnFoot() {
        // Clear all automotive motion flags
        hasHighConfidenceMotion = false
        hasRecentAutomotiveMotion = false

        // Track on-foot timing for stop candidate logic
        lastOnFootAt = Date()
        
        // Log motion for timeline
        driveLogger.log(.motion, type: "motion_on_foot", message: "On-foot motion detected")
        
        switch state {
        case .maybeDriving:
            // On-foot motion negates maybeDriving
            transition(to: .idle, trigger: "motion_on_foot")
            
        case .stopped:
            // KEY LOGIC: Walking/running while stopped = user got out of car
            // The stopped timer being active is our safety gate (speed already < 1mph for 30s)
            logger.info("[ON-FOOT] Walking/running detected while stopped - ending drive immediately")
            driveLogger.log(.decision, type: "on_foot_end", message: "Walking detected while stopped")
            pendingEndReason = .walkingDetected
            transition(to: .ended, trigger: "on_foot_while_stopped")
            
        case .idle, .driving, .ended, .pendingArrival:
            // Ignore - during active driving, GPS is the authority
            // (Could be brief motion noise or phone movement in vehicle)
            break
        }
    }
    
    private func handleLocationUpdate(_ location: CLLocation) {
        // Update current location for UI
        currentLocation = location
        
        // Feed location to accelerometer for coordinate transformation
        motionManager?.updateAccelerometerGPS(location)
        
        // Filter low-accuracy readings
        guard location.horizontalAccuracy <= minAccuracy else {
            logger.debug("Ignoring low-accuracy location: \(location.horizontalAccuracy)m")
            // Track dropped samples (only during active drive)
            if state == .driving || state == .stopped {
                activeDrive?.droppedSampleCount += 1
            }
            return
        }
        
        // Compute speed with fallback when CLLocation.speed is invalid
        let speedMPH = speedInMPH(for: location)

        // Track recent locations for distance-based stop detection
        updateRecentLocations(location)

        // Post-drive monitoring deadline check (background-safe)
        updatePostDriveMonitoringIfNeeded()
        
        // Update lastProcessedLocation for next fallback calculation
        defer { lastProcessedLocation = location }
        
        switch state {
        case .idle:
            // Dwell: if we're idling and inside a saved Place, ensure an active visit exists.
            placeVisitManager.updateDwellIfNeeded(currentLocation: location)

            // Speed can trigger maybeDriving, but guard against a single bogus/stale speed sample
            // that often appears immediately after app launch/resume.
            let ageSeconds = Date().timeIntervalSince(location.timestamp)
            if ageSeconds > idleStartLocationMaxAgeSeconds {
                idleHighSpeedStart = nil
                logger.debug("[IDLE] Ignoring stale location for start decision (age=\(Int(ageSeconds))s)")
                break
            }

            if speedMPH >= maybeDrivingSpeedThreshold {
                if idleHighSpeedStart == nil {
                    idleHighSpeedStart = location.timestamp
                    logger.debug("[IDLE] Speed ≥ threshold; starting confirm window")
                } else if let start = idleHighSpeedStart,
                          location.timestamp.timeIntervalSince(start) >= idleSpeedConfirmSeconds {
                    idleHighSpeedStart = nil
                    // Only set reason if not already set by motion event
                    if pendingStartReason == nil {
                        pendingStartReason = .gpsSpeed
                    }
                    transition(to: .maybeDriving, trigger: "gps_speed_confirmed")
                }
            } else {
                idleHighSpeedStart = nil
            }
            
        case .maybeDriving:
            // Buffer location points so drive can start at actual departure point
            locationBuffer.add(location)
            
            // FAST-TRACK: High-confidence motion + speed threshold = immediate start
            if hasHighConfidenceMotion && speedMPH >= drivingConfirmationSpeed {
                logger.info("[FAST-TRACK] High-confidence motion + speed (\(String(format: "%.1f", speedMPH)) mph) → immediate start")
                transition(to: .driving, trigger: "fast_track")
                return
            }
            
            // Standard path: Check for sustained high speed
            if speedMPH >= drivingConfirmationSpeed {
                if sustainedHighSpeedStart == nil {
                    sustainedHighSpeedStart = Date()
                } else if Date().timeIntervalSince(sustainedHighSpeedStart!) >= drivingConfirmationDuration {
                    transition(to: .driving, trigger: "speed_confirmed_sustained")
                }
            } else {
                // Speed dropped, reset verification
                sustainedHighSpeedStart = nil
            }
            
        case .driving:
            // Track first location fix if not recorded
            recordFirstFixIfNeeded(location)
            
            // Track driving confirmation (first time we hit confirmation speed)
            if speedMPH >= drivingConfirmationSpeed && activeDrive?.drivingConfirmedTime == nil {
                activeDrive?.drivingConfirmedTime = Date()
                driveLogger.log(.location, type: "driving_confirmed", message: "Speed exceeded \(Int(drivingConfirmationSpeed)) mph")
            }
            
            // Check for GPS gaps
            trackGPSGapIfNeeded(from: activeDrive?.latestPointTimestamp, to: location.timestamp)
            
            // Record location point with rejection logging
            if let drive = activeDrive {
                let (added, reason, note) = drive.addPointWithReason(location)
                if added {
                    drive.locationSampleCount += 1
                    if let note {
                        logPointAcceptanceNote(note)
                    }
                    periodicallySaveIfNeeded()
                } else if let reason {
                    drive.droppedSampleCount += 1
                    driveLogger.log(.location, type: "point_rejected", message: "\(reason.rawValue) acc=\(Int(location.horizontalAccuracy))m spd=\(String(format: "%.1f", location.speed))m/s")
                }
            }
            
            // Check for low speed (potential stop)
            if speedMPH < stoppedSpeedThreshold {
                if sustainedLowSpeedStart == nil {
                    sustainedLowSpeedStart = Date()
                } else if Date().timeIntervalSince(sustainedLowSpeedStart!) >= stoppedDetectionDuration {
                    transition(to: .stopped, trigger: "low_speed_sustained")
                }
            } else {
                sustainedLowSpeedStart = nil
            }

            // On-foot + low movement => stop candidate (non-saved places)
            let now = Date()
            let onFootRecent = isOnFootRecent(now)
            var lowSpeedCandidateMet = false
            if speedMPH < lowSpeedCandidateThreshold {
                if lowSpeedCandidateStart == nil {
                    lowSpeedCandidateStart = now
                } else if now.timeIntervalSince(lowSpeedCandidateStart!) >= lowSpeedSustainForCandidate {
                    lowSpeedCandidateMet = true
                }
            } else {
                lowSpeedCandidateStart = nil
            }

            let distanceSummary = recentDistanceSummary()
            let hasCoverage = distanceSummary.coverage >= (stopDistanceWindow * 0.5)
            let lowDistanceMet = distanceSummary.samples >= 2
                && hasCoverage
                && distanceSummary.distance <= stopDistanceMaxMeters

            if onFootRecent && (lowSpeedCandidateMet || lowDistanceMet) {
                logger.info("[ON-FOOT] Recent on-foot + low movement detected - entering stopped")
                driveLogger.log(
                    .decision,
                    type: "on_foot_stop_candidate",
                    message: "On-foot + low movement → stopped",
                    metadata: [
                        "speedMPH": String(format: "%.1f", speedMPH),
                        "distanceMeters": String(format: "%.1f", distanceSummary.distance),
                        "coverageSeconds": String(format: "%.0f", distanceSummary.coverage)
                    ]
                )
                transition(to: .stopped, trigger: "on_foot_stop_candidate")
                return
            }
            
            // Check for arrival at saved place when slowing down
            // This catches arrivals even if geofence entry was missed or speed was high at entry
            if speedMPH <= resumeSpeedThreshold {
                // First check: Are we inside a tracked geofence region?
                if !insideRegionIds.isEmpty {
                    logger.info("Speed dropped to \(String(format: "%.1f", speedMPH))mph inside tracked region - starting arrival validation")
                    var meta = stateSnapshotMetadata()
                    meta["reason"] = "region_slowdown"
                    driveLogger.log(.decision, type: "region_slowdown_arrival", message: "Slowdown inside region at \(String(format: "%.1f", speedMPH))mph", metadata: meta)
                    logTraceIfEnabled(type: "pending_arrival_enter", message: "Entered pending arrival (region slowdown)", metadata: meta)
                    transition(to: .pendingArrival, trigger: "region_slowdown")
                    return
                }
                
                // Fallback check: Are we inside a saved place? (covers cases where geofence didn't fire)
                if let place = placeVisitManager.bestMatchingPlace(for: location.coordinate) {
                    logger.info("Speed dropped to \(String(format: "%.1f", speedMPH))mph at place '\(place.name)' - starting arrival validation")
                    var meta = stateSnapshotMetadata()
                    meta["reason"] = "place_slowdown"
                    meta["placeName"] = place.name
                    driveLogger.log(.decision, type: "place_slowdown_arrival", message: "Slowdown at \(place.name) at \(String(format: "%.1f", speedMPH))mph", metadata: meta)
                    logTraceIfEnabled(type: "pending_arrival_enter", message: "Entered pending arrival (place slowdown)", metadata: meta)
                    transition(to: .pendingArrival, trigger: "place_slowdown")
                    return
                }
            }
            
        case .stopped:
            // Track GPS gaps
            trackGPSGapIfNeeded(from: activeDrive?.latestPointTimestamp, to: location.timestamp)
            
            // Record location point with rejection logging
            if let drive = activeDrive {
                let (added, reason, note) = drive.addPointWithReason(location)
                if added {
                    drive.locationSampleCount += 1
                    if let note {
                        logPointAcceptanceNote(note)
                    }
                    periodicallySaveIfNeeded()
                } else if let reason {
                    drive.droppedSampleCount += 1
                    driveLogger.log(.location, type: "point_rejected", message: "\(reason.rawValue) acc=\(Int(location.horizontalAccuracy))m spd=\(String(format: "%.1f", location.speed))m/s")
                }
            }
            
            // Fast-track end: If stopped at a saved place, end drive immediately
            // This avoids waiting for the full stoppedTimeout when user clearly arrived
            if speedMPH < stoppedSpeedThreshold,
               let place = placeVisitManager.bestMatchingPlace(for: location.coordinate) {
                logger.info("[PLACE-ARRIVAL] Stopped at saved place '\(place.name)' - ending drive immediately")
                driveLogger.log(.decision, type: "place_arrival_end", message: "Arrived at \(place.name)")
                
                // Start a PlaceVisit for the arrival
                placeVisitManager.startPlaceVisitForArrival(at: location.coordinate, place: place)

                // Capture end snapshot for stop matching
                captureEndSnapshot(location: location, place: place)
                
                pendingEndReason = .visitArrival
                transition(to: .ended, trigger: "place_arrival")
                return
            }
            
            // Lenient place arrival: If stopped for >30s AND inside a saved place,
            // end drive even with GPS drift (which can show 1-5mph while parked)
            // This catches cases where the user parked but GPS shows spurious speed
            if let stoppedTime = stoppedSince,
               Date().timeIntervalSince(stoppedTime) > 30.0,
               speedMPH < resumeSpeedThreshold,  // More lenient: < 5 mph instead of < 1 mph
               let place = placeVisitManager.bestMatchingPlace(for: location.coordinate) {
                logger.info("[PLACE-ARRIVAL-LENIENT] Stopped >\(Int(Date().timeIntervalSince(stoppedTime)))s at saved place '\(place.name)' - ending drive")
                driveLogger.log(.decision, type: "place_arrival_lenient", message: "Arrived at \(place.name) after \(Int(Date().timeIntervalSince(stoppedTime)))s")
                
                placeVisitManager.startPlaceVisitForArrival(at: location.coordinate, place: place)

                // Capture end snapshot for stop matching
                captureEndSnapshot(location: location, place: place)
                
                pendingEndReason = .visitArrival
                transition(to: .ended, trigger: "place_arrival_lenient")
                return
            }
            
            // Check for resume (debounced to avoid walk/noise bounce-backs).
            let now = Date()
            let onFootRecent = isOnFootRecent(now)
            let requiredResumeSpeed = onFootRecent
                ? max(resumeSpeedThreshold, resumeSpeedThresholdOnFootRecent)
                : resumeSpeedThreshold

            if speedMPH >= requiredResumeSpeed {
                if stoppedResumeCandidateStart == nil {
                    stoppedResumeCandidateStart = now
                } else if now.timeIntervalSince(stoppedResumeCandidateStart!) >= stoppedResumeSustainDuration {
                    transition(
                        to: .driving,
                        trigger: onFootRecent ? "resume_speed_sustained_on_foot" : "resume_speed_sustained"
                    )
                    return
                }
            } else {
                stoppedResumeCandidateStart = nil
            }
            
        case .ended:
            // Ignore - drive finalized
            break
            
        case .pendingArrival:
            // If speed picks up significantly during validation window, it's a false arrival
            // (e.g. slowed down for gate, then accelerated)
            if speedMPH > 20.0 {
                logger.info("Speed increased to \(String(format: "%.1f", speedMPH))mph during pending arrival - resuming drive")
                transition(to: .driving, trigger: "pending_arrival_speed_resume")
            }
        }
    }
    
    /// Record first location fix for the active drive
    private func recordFirstFixIfNeeded(_ location: CLLocation) {
        guard !hasRecordedFirstFix, let drive = activeDrive else { return }
        
        if drive.firstLocationFixTime == nil {
            drive.firstLocationFixTime = location.timestamp
            driveLogger.logLocationUpdate(
                accuracy: location.horizontalAccuracy,
                speed: location.speed,
                isFirstFix: true
            )
        }
        hasRecordedFirstFix = true
    }
    
    /// Track GPS gaps for quality metrics
    private func trackGPSGapIfNeeded(from lastTimestamp: Date?, to currentTimestamp: Date) {
        guard let last = lastTimestamp else { return }
        let gap = currentTimestamp.timeIntervalSince(last)
        
        // Log gaps longer than 60 seconds (shorter gaps are normal iOS background behavior)
        if gap > 60 {
            driveLogger.log(
                .anomaly,
                type: "gps_gap",
                message: "GPS gap detected: \(String(format: "%.0f", gap))s",
                metadata: [
                    "gapSeconds": String(format: "%.1f", gap),
                    "state": state.rawValue,
                    "appState": UIApplication.shared.applicationState == .background ? "background" : "foreground",
                    "highAccuracy": String(locationManager?.isHighAccuracyMode ?? false)
                ]
            )

            if let drive = activeDrive, gap > drive.maxGapBetweenSamples {
                drive.maxGapBetweenSamples = gap
            }
        }
    }

    /// Log non-fatal handling notes for accepted points.
    private func logPointAcceptanceNote(_ note: Drive.PointAcceptanceNote) {
        switch note {
        case .distanceSkippedLargeGap(let gapSeconds, let skippedMeters):
            driveLogger.log(
                .anomaly,
                type: "distance_gap_skipped",
                message: "Skipped distance across large gap (\(Int(gapSeconds))s)",
                metadata: [
                    "gapSeconds": String(format: "%.1f", gapSeconds),
                    "skippedMeters": String(format: "%.1f", skippedMeters)
                ]
            )
        }
    }
    
    /// Compute speed for a location, with fallback to distance/time calculation
    /// when CLLocation.speed is invalid (< 0).
    /// Returns speed in m/s.
    private func computeSpeed(for location: CLLocation) -> Double {
        // If CLLocation has valid speed, use it
        if location.speed >= 0 {
            return location.speed
        }
        
        // Fallback: compute from distance/time if we have a previous location
        guard let lastLocation = lastProcessedLocation else {
            return 0
        }
        
        let timeDelta = location.timestamp.timeIntervalSince(lastLocation.timestamp)
        guard timeDelta > 0.5 else { // Require at least 0.5s between samples
            return 0
        }
        
        let distance = location.distance(from: lastLocation)
        let computedSpeed = distance / timeDelta
        
        // Cap at reasonable max speed to filter GPS jumps
        guard computedSpeed <= maxFallbackSpeed else {
            logger.debug("Fallback speed too high (\(String(format: "%.1f", computedSpeed)) m/s) - capping")
            return 0
        }
        
        logger.debug("Using fallback speed: \(String(format: "%.1f", computedSpeed)) m/s")
        return computedSpeed
    }

    /// Track recent locations for distance-based stop detection
    private func updateRecentLocations(_ location: CLLocation) {
        if let last = recentLocations.last {
            let gap = location.timestamp.timeIntervalSince(last.timestamp)
            if gap > stopDistanceWindow {
                recentLocations = [location]
                return
            }
        }

        recentLocations.append(location)
        let cutoff = location.timestamp.addingTimeInterval(-stopDistanceWindow)
        while let first = recentLocations.first, first.timestamp < cutoff {
            recentLocations.removeFirst()
        }
    }

    /// Summarize recent movement distance
    private func recentDistanceSummary() -> (distance: Double, coverage: TimeInterval, samples: Int) {
        guard recentLocations.count >= 2 else {
            return (distance: 0, coverage: 0, samples: recentLocations.count)
        }

        var distance: Double = 0
        for index in 1..<recentLocations.count {
            distance += recentLocations[index].distance(from: recentLocations[index - 1])
        }
        let coverage = recentLocations.last!.timestamp.timeIntervalSince(recentLocations.first!.timestamp)
        return (distance: distance, coverage: coverage, samples: recentLocations.count)
    }

    /// Whether on-foot motion was detected recently enough to influence stop logic
    private func isOnFootRecent(_ now: Date = Date()) -> Bool {
        guard let lastOnFootAt else { return false }
        return now.timeIntervalSince(lastOnFootAt) <= onFootRecentWindow
    }

    private func stateSnapshotMetadata() -> [String: String] {
        var meta: [String: String] = [
            "state": state.rawValue,
            "appState": UIApplication.shared.applicationState == .background ? "background" : "foreground",
            "insideRegionCount": String(insideRegionIds.count),
            "onFootRecent": String(isOnFootRecent())
        ]

        if let location = currentLocation {
            let speedMPH = max(0, speedInMPH(for: location))
            meta["speedMPH"] = String(format: "%.1f", speedMPH)
            meta["accuracyM"] = String(format: "%.0f", location.horizontalAccuracy)
        }

        let distanceSummary = recentDistanceSummary()
        meta["distanceMeters"] = String(format: "%.1f", distanceSummary.distance)
        meta["coverageSeconds"] = String(format: "%.0f", distanceSummary.coverage)

        return meta
    }

    private func logTraceIfEnabled(type: String, message: String, metadata: [String: String] = [:]) {
        guard traceLoggingEnabled else { return }
        driveLogger.logTrace(type: type, message: message, metadata: metadata)
    }

    /// Capture end snapshot for stop matching (location + optional saved place)
    private func captureEndSnapshot(location: CLLocation? = nil, place: Place? = nil) {
        guard let drive = activeDrive else { return }

        if let place, drive.endPlaceId == nil {
            drive.endPlaceId = place.placeId
        }

        if (drive.endLatitude == nil || drive.endLongitude == nil),
           let coord = (location ?? currentLocation)?.coordinate {
            drive.endLatitude = coord.latitude
            drive.endLongitude = coord.longitude
        }
    }

    
    private func handleSignificantLocationChange() {
        // SLC is used to wake the app, not to infer driving
        logger.info("Significant location change received in state: \(self.state.rawValue)")
        driveLogger.log(.system, type: "slc_wake", message: "SLC wake in state: \(self.state.rawValue)")

        // In case we're still in post-drive monitoring, check deadline.
        updatePostDriveMonitoringIfNeeded()

        // Low-risk metadata improvement: if we're idle, remember that the wake came from SLC.
        // This doesn't start a drive; it just informs the eventual startReason if speed/motion confirms later.
        if state == .idle, pendingStartReason == nil {
            pendingStartReason = .significantLocationChange
        }
        
        // Request one-shot GPS to get fresh speed data for drive detection
        if state == .idle {
            requestOneShotGPSIfNeeded(reason: "slc_wake")
        }
    }
    
    private func handleVisitArrival(_ visit: CLVisit) {
        // Start/refresh dwell based on visit arrival.
        placeVisitManager.startPlaceVisitIfPossible(from: visit)
        
        // Log the visit arrival for timeline
        driveLogger.log(.location, type: "visit_arrival", message: "CLVisit arrival at (\(String(format: "%.4f", visit.coordinate.latitude)), \(String(format: "%.4f", visit.coordinate.longitude)))")

        switch state {
        case .driving, .stopped:
            // Visit arrival indicates we may have arrived - validate before ending
            logger.info("Visit arrival detected - starting arrival validation")
            pendingEndReason = .visitArrival
            var meta = stateSnapshotMetadata()
            meta["reason"] = "visit_arrival"
            driveLogger.log(.decision, type: "visit_arrival_pending", message: "Visit arrival - validating arrival", metadata: meta)
            logTraceIfEnabled(type: "pending_arrival_enter", message: "Entered pending arrival (visit arrival)", metadata: meta)
            transition(to: .pendingArrival, trigger: "visit_arrival")
            
        case .idle, .maybeDriving, .ended, .pendingArrival:
            break
        }
    }
    
    private func handleVisitDeparture(_ visit: CLVisit) {
        placeVisitManager.endActivePlaceVisitIfNeeded(from: visit)
        
        // Log the visit departure for timeline
        driveLogger.log(.location, type: "visit_departure", message: "CLVisit departure from (\(String(format: "%.4f", visit.coordinate.latitude)), \(String(format: "%.4f", visit.coordinate.longitude)))")

        switch state {
        case .idle:
            // Departing a location *might* indicate start of drive, but CLVisit can be triggered by walking.
            // Low-risk gate: only begin verification if we have corroborating speed evidence.
            let speedMPH = currentSpeedMPH
            guard speedMPH >= maybeDrivingSpeedThreshold else {
                logger.info("Ignoring visit departure - insufficient speed evidence (\(String(format: "%.1f", speedMPH))mph)")
                driveLogger.log(.decision, type: "visit_departure_ignored", message: "Visit departure ignored: speed \(String(format: "%.1f", speedMPH))mph")
                return
            }
            pendingStartReason = .visitDeparture
            transition(to: .maybeDriving, trigger: "visit_departure")
            
        case .maybeDriving, .driving, .stopped, .ended, .pendingArrival:
            break
        }
    }

    private func handleGeofenceExit(regionId: String) {
        logger.info("Geofence Exit detected for \(regionId) - Confidence Booster")
        
        // Remove from tracked regions
        insideRegionIds.remove(regionId)
        
        // Log the geofence exit for timeline
        driveLogger.log(.decision, type: "geofence_exit", message: "Left saved place: \(regionId)")
        
        switch state {
        case .idle:
            // Strong signal to start checking from idle
            logger.info("Triggering .maybeDriving from Geofence Exit")
            pendingStartReason = .geofenceExit
            transition(to: .maybeDriving, trigger: "geofence_exit")
            
        case .stopped:
            // Exiting a region while stopped *might* imply moving again, but region edge jitter is common.
            // Low-risk gate: require some speed evidence before resuming.
            let speedMPH = currentSpeedMPH
            pendingStartReason = .geofenceExit  // For logging consistency
            if speedMPH >= resumeSpeedThreshold {
                logger.info("Resuming .driving from .stopped due to Geofence Exit (speed \(String(format: "%.1f", speedMPH))mph)")
                transition(to: .driving, trigger: "geofence_exit_resume")
            } else if speedMPH >= maybeDrivingSpeedThreshold {
                logger.info("Leaving geofence while stopped - entering .maybeDriving (speed \(String(format: "%.1f", speedMPH))mph)")
                transition(to: .maybeDriving, trigger: "geofence_exit_maybe")
            } else {
                logger.info("Ignoring geofence exit while stopped - insufficient speed evidence (\(String(format: "%.1f", speedMPH))mph)")
                driveLogger.log(.decision, type: "geofence_exit_ignored", message: "Geofence exit ignored: speed \(String(format: "%.1f", speedMPH))mph")
            }
            
        case .pendingArrival:
            // Explicit signal that we did NOT arrive (drove through)
            logger.info("Geofence exit during pending arrival - resuming drive")
            driveLogger.log(.decision, type: "false_arrival_resume", message: "Exited geofence during validation window")
            transition(to: .driving, trigger: "geofence_exit_pending_resume")
            
        case .maybeDriving, .driving, .ended:
            break
        }
    }
    
    private func handleGeofenceEntry(regionId: String) {
        logger.info("Geofence Entry detected for \(regionId)")
        
        // Always track that we're inside this region (critical for arrival detection)
        insideRegionIds.insert(regionId)
        
        let speedMPH = currentSpeedMPH
        driveLogger.log(.decision, type: "geofence_entry", message: "Entered \(regionId) at \(String(format: "%.1f", speedMPH))mph")
        
        switch state {
        case .driving, .stopped:
            if speedMPH < geofenceImmediateEndSpeedMPH {
                logger.info("Geofence Entry at: \(regionId) - low speed \(String(format: "%.1f", speedMPH))mph, ending drive")
                var meta = stateSnapshotMetadata()
                meta["reason"] = "geofence_entry_low_speed"
                driveLogger.log(.decision, type: "geofence_entry_end", message: "Entered \(regionId) at \(String(format: "%.1f", speedMPH))mph - ending", metadata: meta)
                var place: Place?
                if let location = currentLocation {
                    place = placeVisitManager.bestMatchingPlace(for: location.coordinate)
                }
                if place == nil {
                    place = placeVisitManager.place(for: regionId)
                }
                if let location = currentLocation, let place {
                    placeVisitManager.startPlaceVisitForArrival(at: location.coordinate, place: place)
                }
                captureEndSnapshot(location: currentLocation, place: place)
                pendingEndReason = .geofenceEntryLowSpeed
                transition(to: .ended, trigger: "geofence_entry_low_speed")
                return
            }
            // If already slow enough, start arrival validation immediately
            if speedMPH <= resumeSpeedThreshold {
                logger.info("Geofence Entry at: \(regionId) - starting pending arrival validation (speed \(String(format: "%.1f", speedMPH))mph)")
                var meta = stateSnapshotMetadata()
                meta["reason"] = "geofence_entry_pending"
                driveLogger.log(.decision, type: "geofence_entry_pending", message: "Entered \(regionId), validating arrival...", metadata: meta)
                logTraceIfEnabled(type: "pending_arrival_enter", message: "Entered pending arrival (geofence entry)", metadata: meta)
                transition(to: .pendingArrival, trigger: "geofence_entry")
            } else {
                // Still moving - region is tracked, arrival will be checked when speed drops
                logger.info("Geofence Entry at: \(regionId) - tracking region (speed \(String(format: "%.1f", speedMPH))mph, will check on slowdown)")
                var meta = stateSnapshotMetadata()
                meta["reason"] = "geofence_entry_tracked"
                driveLogger.log(.decision, type: "geofence_entry_tracked", message: "Entered \(regionId) at \(String(format: "%.1f", speedMPH))mph - awaiting slowdown", metadata: meta)
            }
            
        case .maybeDriving:
            // Haven't confirmed drive yet, but arrived at a place - cancel detection
            logger.info("Canceling drive detection - arrived at saved place: \(regionId)")
            transition(to: .idle, trigger: "geofence_entry_cancel")
            
        case .idle, .ended, .pendingArrival:
            // Not driving, ignore (but region is still tracked)
            break
        }
    }

    
    private func handleTimerExpired(_ kind: TimerKind) {
        logger.info("Timer expired: \(kind.rawValue) in state: \(self.state.rawValue)")
        
        // Log timer expiration for timeline
        driveLogger.log(.decision, type: "timer_expired", message: "\(kind.rawValue) timer expired in state: \(self.state.rawValue)")
        
        switch kind {
        case .maybeDrivingVerification:
            if state == .maybeDriving {
                // Verification period expired without confirming drive
                transition(to: .idle, trigger: "verification_timeout")
            }
            
        case .stoppedTimeout:
            if state == .stopped {
                // Been stopped too long - end drive
                transition(to: .ended, trigger: "stopped_timeout")
            }
            
        case .safetyEnd:
            if state == .driving || state == .stopped {
                // Safety limit reached - force end
                logger.warning("Safety timer expired - force ending drive")
                pendingEndReason = .safetyTimeout
                transition(to: .ended, trigger: "safety_timeout")
            }
            
        case .pendingArrival:
            if state == .pendingArrival {
                logger.info("Pending arrival validation complete - confirming arrival")
                driveLogger.log(.decision, type: "arrival_confirmed", message: "Pending arrival validated via timer")

                // Validate with current speed/location freshness before ending
                if let location = currentLocation {
                    let age = Date().timeIntervalSince(location.timestamp)
                    let speedMPH = max(0, speedInMPH(for: location))
                    if age > pendingArrivalMaxLocationAgeSeconds {
                        logger.info("Pending arrival cancelled: stale location (age \(Int(age))s)")
                        var meta = stateSnapshotMetadata()
                        meta["reason"] = "stale_location"
                        meta["ageSeconds"] = String(format: "%.0f", age)
                        driveLogger.log(.decision, type: "arrival_rejected", message: "Stale location (age \(Int(age))s)", metadata: meta)
                        logTraceIfEnabled(type: "pending_arrival_reject", message: "Rejected pending arrival (stale location)", metadata: meta)
                        transition(to: .driving, trigger: "pending_arrival_stale_location")
                        return
                    }

                    if speedMPH > resumeSpeedThreshold {
                        logger.info("Pending arrival cancelled: still moving (\(String(format: "%.1f", speedMPH))mph)")
                        var meta = stateSnapshotMetadata()
                        meta["reason"] = "speed_high"
                        driveLogger.log(.decision, type: "arrival_rejected", message: "Speed \(String(format: "%.1f", speedMPH))mph", metadata: meta)
                        logTraceIfEnabled(type: "pending_arrival_reject", message: "Rejected pending arrival (speed high)", metadata: meta)
                        transition(to: .driving, trigger: "pending_arrival_speed_high")
                        return
                    }
                }

                let distanceSummary = recentDistanceSummary()
                let hasCoverage = distanceSummary.coverage >= (stopDistanceWindow * 0.5)
                if distanceSummary.samples >= 2,
                   hasCoverage,
                   distanceSummary.distance > stopDistanceMaxMeters {
                    logger.info("Pending arrival cancelled: distance \(String(format: "%.1f", distanceSummary.distance))m in last window")
                    var meta = stateSnapshotMetadata()
                    meta["reason"] = "distance_high"
                    meta["distanceMeters"] = String(format: "%.1f", distanceSummary.distance)
                    meta["coverageSeconds"] = String(format: "%.0f", distanceSummary.coverage)
                    driveLogger.log(
                        .decision,
                        type: "arrival_rejected",
                        message: "Distance \(String(format: "%.1f", distanceSummary.distance))m",
                        metadata: meta
                    )
                    logTraceIfEnabled(type: "pending_arrival_reject", message: "Rejected pending arrival (distance high)", metadata: meta)
                    transition(to: .driving, trigger: "pending_arrival_distance_high")
                    return
                }

                // Finalize the arrival
                if let location = currentLocation {
                    let place = placeVisitManager.bestMatchingPlace(for: location.coordinate)
                    captureEndSnapshot(location: location, place: place)
                } else {
                    captureEndSnapshot()
                }
                pendingEndReason = .visitArrival
                transition(to: .ended, trigger: "arrival_confirmed")
            }
        }
    }
    
    // MARK: - State Transitions
    
    private func transition(to newState: DriveState, trigger: String = "direct") {
        let oldState = state
        
        // Cancel one-shot GPS when leaving idle (drive detection succeeded)
        if oldState == .idle && newState != .idle {
            locationManager?.cancelOneShotLocation()
        }
        
        // Validate transition
        guard isValidTransition(from: oldState, to: newState) else {
            logger.error("[ERROR] Illegal transition attempted: \(oldState.rawValue) -> \(newState.rawValue)")
            return
        }
        
        // Verbose transition logging
        if verboseLogging {
            let speedInfo = currentLocation.map { String(format: "%.1f mph", max(0, $0.speed * msToMPH)) } ?? "?"  // Raw iOS speed
            logger.info("[STATE] \(oldState.rawValue) -> \(newState.rawValue) speed=\(speedInfo) trigger=\(trigger)")
        } else {
            logger.info("Transition: \(oldState.rawValue) -> \(newState.rawValue)")
        }
        
        // Log transition for Drive Inspector
        driveLogger.logStateTransition(
            from: oldState.rawValue,
            to: newState.rawValue,
            trigger: trigger,
            metadata: stateSnapshotMetadata()
        )
        
        // Exit actions
        exitState(oldState)
        
        // Update state
        state = newState
        
        // Entry actions
        enterState(newState)
    }
    
    /// Special transition for cold-start recovery that bypasses normal idle → driving restriction.
    /// This is safe because we've already verified motion + speed evidence.
    private func transitionDirectToDriving(trigger: String) {
        let oldState = state
        
        // Log the special transition
        if verboseLogging {
            let speedInfo = currentLocation.map { String(format: "%.1f mph", max(0, $0.speed * msToMPH)) } ?? "?"  // Raw iOS speed
            logger.info("[STATE] \(oldState.rawValue) -> driving (direct) speed=\(speedInfo) trigger=\(trigger)")
        }
        
        driveLogger.logStateTransition(
            from: oldState.rawValue,
            to: DriveState.driving.rawValue,
            trigger: trigger,
            metadata: stateSnapshotMetadata()
        )
        
        // Exit old state
        exitState(oldState)
        
        // Update state
        state = .driving
        
        // Enter new state
        enterState(.driving)
    }
    
    private func isValidTransition(from: DriveState, to: DriveState) -> Bool {
        switch (from, to) {
        case (.idle, .maybeDriving): return true
        case (.maybeDriving, .driving): return true
        case (.maybeDriving, .idle): return true
        case (.driving, .stopped): return true
        case (.driving, .ended): return true
        case (.stopped, .driving): return true
        case (.stopped, .ended): return true
        
        // Pending Arrival Transitions
        case (.driving, .pendingArrival): return true
        case (.stopped, .pendingArrival): return true
        case (.pendingArrival, .driving): return true // False arrival (resume)
        case (.pendingArrival, .ended): return true   // Confirmed arrival
        
        // Ended cleanup transition (internal)
        case (.ended, .idle): return true
            
        // Illegal transitions (idle -> driving requires transitionDirectToDriving)
        case (.idle, .driving): return false
        case (.idle, .ended): return false
        case (.maybeDriving, .ended): return false
            
        // Same state (no-op)
        case (let a, let b) where a == b: return false
            
        default: return false
        }
    }
    
    private func exitState(_ state: DriveState) {
        // Cancel timers on exit
        switch state {
        case .maybeDriving:
            verificationTimer?.cancel()
            verificationTimer = nil
            sustainedHighSpeedStart = nil
            hasHighConfidenceMotion = false  // Reset fast-track flag
            // Note: Don't clear locationBuffer here - it's consumed in enterState(.driving)
            
        case .stopped:
            stoppedTimer?.cancel()
            stoppedTimer = nil
            stoppedSince = nil
            stoppedResumeCandidateStart = nil
            // Clear persisted stoppedSince when resuming (MUST be durable)
            if let drive = activeDrive {
                drive.stoppedSince = nil
                persistStoppedSince(for: drive)
            }
            
        case .pendingArrival:
            pendingArrivalTimer?.cancel()
            pendingArrivalTimer = nil
            
        case .driving:
            sustainedLowSpeedStart = nil
            lowSpeedCandidateStart = nil
            stoppedResumeCandidateStart = nil
            
        case .idle, .ended:
            break
        }
    }
    
    private func enterState(_ state: DriveState) {
        switch state {
        case .idle:
            // Clean up any active drive reference (but don't delete)
            activeDrive = nil
            // Clear any buffered locations from failed maybeDriving
            locationBuffer.clear()
            idleHighSpeedStart = nil
            // Clear tracked geofence regions (fresh start for next drive detection)
            // This is safe because geofence EXIT is the primary start trigger, and
            // the fallback bestMatchingPlace check handles cases without geofence events
            insideRegionIds.removeAll()
            // Clear pending reasons to prevent stale values carrying to next drive
            // (e.g., if maybeDriving → idle via verification timeout)
            pendingStartReason = nil
            pendingEndReason = nil
            lastOnFootAt = nil
            lowSpeedCandidateStart = nil
            stoppedResumeCandidateStart = nil
            recentLocations.removeAll()
            // Reset one-shot debounce for next departure
            resetOneShotDebounce()
            // Release driving high-accuracy if we're not in post-drive monitoring
            if !isPostDriveMonitoring {
                locationManager?.disableHighAccuracy(reason: "driving")
            }
            
        case .pendingArrival:
            locationManager?.enableHighAccuracy(reason: "driving")
            startPendingArrivalTimer()
            
        case .maybeDriving:
            // Leaving a dwell session implies we're moving.
            placeVisitManager.endActivePlaceVisitForDeparture()
            
            // Cancel post-drive monitoring if we're starting to detect a new drive
            cancelPostDriveMonitoring()

            locationManager?.enableHighAccuracy(reason: "driving")
            // Start verification timer
            startVerificationTimer()
            
        case .driving:
            // Driving starts: ensure we are not in an active dwell.
            placeVisitManager.endActivePlaceVisitForDeparture()
            recentLocations.removeAll()
            locationManager?.enableHighAccuracy(reason: "driving")

            // Create new drive if needed
            if activeDrive == nil {
                let reason = pendingStartReason ?? .motionActivity
                let bufferedLocations = locationBuffer.consumeAll()
                createNewDrive(startReason: reason, bufferedLocations: bufferedLocations)
                pendingStartReason = nil // Consume
                
                // Send notification (only on fresh drive start)
                NotificationService.shared.sendDriveStarted()
            }
            // Start safety timer
            startSafetyTimer()
            
        case .stopped:
            // Track when stopped started (for timeout calculation)
            let now = Date()
            stoppedSince = now
            stoppedResumeCandidateStart = nil
            // Persist to Drive model for crash/kill recovery (MUST be durable)
            if let drive = activeDrive {
                drive.stoppedSince = now
                persistStoppedSince(for: drive)
            }
            // Start stopped timeout timer
            let onFootRecent = isOnFootRecent(now)
            let timeoutOverride = onFootRecent
                ? min(stoppedTimeoutSeconds, onFootEarlyEndDelay)
                : nil
            startStoppedTimer(timeoutOverride: timeoutOverride)
            locationManager?.enableHighAccuracy(reason: "driving")
            
        case .ended:
            // Finalize drive with the pending reason (or default to inactivityTimeout)
            let reason = pendingEndReason ?? .inactivityTimeout
            pendingEndReason = nil  // Consume
            finalizeDrive(endReason: reason)
            // Cancel safety timer
            safetyTimer?.cancel()
            safetyTimer = nil
            
            if UIApplication.shared.applicationState == .active {
                // Start post-drive monitoring grace period in foreground only.
                // In background/inactive, timers and callbacks are suspension-prone, which can
                // leave the location indicator stuck until the app is reopened.
                startPostDriveMonitoring()
            } else {
                // Deterministic teardown for background-ended drives.
                isPostDriveMonitoring = false
                postDriveMonitoringDeadline = nil
                locationManager?.disableHighAccuracy(reason: "driving")
                resetOneShotDebounce()
                logger.info("[POST-DRIVE] Ended while backgrounded - disabled high-accuracy immediately")
            }
            
            // Move back to idle after a brief delay using proper transition.
            // This ensures SwiftUI onChange observers fire correctly.
            Task {
                try? await Task.sleep(for: .seconds(1))
                guard self.state == .ended else { return }
                // Use transition() to properly trigger state observers and enterState actions
                self.transition(to: .idle, trigger: "ended_cleanup")
            }
        }
    }
    
    // MARK: - Timer Management
    
    private func startVerificationTimer() {
        let timeout = verificationTimeout
        logger.debug("Starting verification timer: \(Int(timeout))s")
        verificationTimer = Task {
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            handle(.timerExpired(.maybeDrivingVerification))
        }
    }
    
    private func startStoppedTimer() {
        startStoppedTimer(timeoutOverride: nil)
    }

    private func startStoppedTimer(timeoutOverride: TimeInterval?) {
        let timeout = timeoutOverride ?? stoppedTimeoutSeconds
        stoppedTimer = Task {
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            handle(.timerExpired(.stoppedTimeout))
        }
    }
    
    private func startSafetyTimer() {
        safetyTimer = Task {
            try? await Task.sleep(for: .seconds(safetyMaxDriveHours * 3600))
            guard !Task.isCancelled else { return }
            handle(.timerExpired(.safetyEnd))
        }
    }
    
    private func startPendingArrivalTimer() {
        // 25-30s window to validate arrival
        let timeout: TimeInterval = 30.0
        logger.debug("Starting pending arrival timer: \(Int(timeout))s")
        pendingArrivalTimer = Task {
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            handle(.timerExpired(.pendingArrival))
        }
    }
    
    // MARK: - Durable Persistence Helpers
    
    /// Persist stoppedSince to SwiftData immediately.
    /// This ensures the stopped timestamp survives app termination.
    private func persistStoppedSince(for drive: Drive) {
        guard let modelContext else { return }
        do {
            try modelContext.save()
            logger.debug("[PERSIST] stoppedSince=\(drive.stoppedSince?.description ?? "nil") saved for drive \(drive.shortId)")
        } catch {
            logger.error("[PERSIST] Failed to save stoppedSince: \(error.localizedDescription)")
        }
    }
    
    /// Start post-drive monitoring grace period.
    /// Keeps high-accuracy tracking active to detect continued driving after a potentially false arrival.
    private func startPostDriveMonitoring() {
        isPostDriveMonitoring = true
        let grace = currentPostDriveGrace()
        postDriveMonitoringDeadline = Date().addingTimeInterval(grace)
        logger.info("[POST-DRIVE] Starting \(Int(grace))s monitoring grace period")
        locationManager?.enableHighAccuracy(reason: "driving")
    }
    
    /// Cancel post-drive monitoring (e.g., when a new drive starts)
    private func cancelPostDriveMonitoring() {
        guard isPostDriveMonitoring else { return }
        
        isPostDriveMonitoring = false
        postDriveMonitoringDeadline = nil
        logger.info("[POST-DRIVE] Monitoring cancelled - new drive detected")
    }

    private func currentPostDriveGrace() -> TimeInterval {
        UIApplication.shared.applicationState == .active
            ? postDriveMonitoringDurationForeground
            : postDriveMonitoringDurationBackground
    }

    private func updatePostDriveMonitoringIfNeeded(now: Date = Date()) {
        guard isPostDriveMonitoring else { return }

        let grace = currentPostDriveGrace()
        if postDriveMonitoringDeadline == nil {
            postDriveMonitoringDeadline = now.addingTimeInterval(grace)
        }

        if UIApplication.shared.applicationState != .active,
           let deadline = postDriveMonitoringDeadline {
            let shortened = now.addingTimeInterval(grace)
            if deadline > shortened {
                postDriveMonitoringDeadline = shortened
                logger.info("[POST-DRIVE] Shortened grace to \(Int(grace))s (background)")
            }
        }

        if let deadline = postDriveMonitoringDeadline, now >= deadline {
            endPostDriveMonitoring(trigger: "post_drive_deadline")
        }
    }

    private func endPostDriveMonitoring(trigger: String) {
        guard isPostDriveMonitoring else { return }

        isPostDriveMonitoring = false
        postDriveMonitoringDeadline = nil
        locationManager?.disableHighAccuracy(reason: "driving")
        resetOneShotDebounce()
        logger.info("[POST-DRIVE] Monitoring ended - disabled high-accuracy tracking")

        if state == .ended {
            transition(to: .idle, trigger: trigger)
        }
    }
    
    // MARK: - Persistence
    
    private func createNewDrive(startReason: DriveStartReason = .motionActivity, bufferedLocations: [CLLocation] = []) {
        guard let modelContext else {
            logger.error("ModelContext not configured - cannot create drive")
            return
        }
        
        // Determine the actual start time from buffered locations or current time
        let startTime = bufferedLocations.first?.timestamp ?? Date()
        let drive = Drive(startTime: startTime)
        drive.startReason = startReason
        
        // Add buffered locations first (these are the points captured during maybeDriving)
        var addedCount = 0
        for location in bufferedLocations {
            if drive.addPoint(location) {
                addedCount += 1
                if drive.firstLocationFixTime == nil {
                    drive.firstLocationFixTime = location.timestamp
                }
            }
        }
        if addedCount > 0 {
            drive.locationSampleCount = addedCount
            drive.bufferedPointCount = addedCount  // Track for analytics
            logger.info("[BUFFER] Promoted \(addedCount) buffered points to new drive (started at buffer origin)")
        }
        
        // Add current location if we have one and buffer was empty
        if bufferedLocations.isEmpty, let location = currentLocation {
            if drive.addPoint(location) {
                drive.firstLocationFixTime = location.timestamp
                drive.locationSampleCount = 1
                logger.debug("First point added to new drive at accuracy \(Int(location.horizontalAccuracy))m")
            } else {
                logger.info("First location rejected (accuracy: \(Int(location.horizontalAccuracy))m) - awaiting better fix")
            }
        }
        
        modelContext.insert(drive)
        activeDrive = drive
        pointsSinceLastSave = 0
        // Only mark first-fix as recorded if we actually accepted a point (and set firstLocationFixTime).
        // If the initial location was rejected (e.g. poor accuracy), we still want recordFirstFixIfNeeded(...) to run later.
        hasRecordedFirstFix = (drive.firstLocationFixTime != nil)
        
        // Start accelerometer for G-force detection
        if let mm = motionManager {
            mm.startAccelerometer()
        } else {
            logger.error("[GFORCE] ⚠️ Cannot start accelerometer - motionManager is nil! Setup race condition?")
        }
        
        // Attach logger to this drive
        driveLogger.attach(to: drive, context: modelContext)
        
        // Log buffer promotion if any points were buffered
        if drive.bufferedPointCount > 0 {
            driveLogger.log(
                .location,
                type: "buffer_promoted",
                message: "Promoted \(drive.bufferedPointCount) buffered points from maybeDriving",
                metadata: [
                    "bufferedPointCount": String(drive.bufferedPointCount),
                    "startReason": startReason.rawValue
                ]
            )
        }
        
        // Log the decision that created this drive
        let startSpeedMS: Double
        if let location = currentLocation {
            startSpeedMS = computeSpeed(for: location)
        } else {
            startSpeedMS = 0
        }
        let decision = DriveDecision.driveStarted(
            reason: startReason,
            speed: startSpeedMS,
            motionConfidence: "unknown",
            appState: UIApplication.shared.applicationState == .background ? "background" : "foreground"
        )
        driveLogger.logDecision(decision)
        
        logger.info("Created new drive: \(drive.shortId)")
        logger.info("[SETTINGS] stoppedTimeout=\(Int(self.stoppedTimeoutMinutes))min stoppedDetection=\(Int(self.stoppedDetectionDuration))s drivingConfirm=\(Int(self.drivingConfirmationDuration))s")
    }
    
    private func finalizeDrive(endReason: DriveEndReason = .inactivityTimeout) {
        guard let drive = activeDrive else { return }

        // Ensure an end snapshot exists for stop matching
        if drive.endLatitude == nil || drive.endLongitude == nil {
            if let location = currentLocation {
                drive.endLatitude = location.coordinate.latitude
                drive.endLongitude = location.coordinate.longitude
            } else if let lastPoint = drive.pointsChronological.last {
                drive.endLatitude = lastPoint.latitude
                drive.endLongitude = lastPoint.longitude
            }
        }
        if drive.endPlaceId == nil, let location = currentLocation {
            if let place = placeVisitManager.bestMatchingPlace(for: location.coordinate) {
                drive.endPlaceId = place.placeId
            }
        }
        
        // Stop accelerometer
        motionManager?.stopAccelerometer()
        
        // Set end metadata
        drive.endReason = endReason
        drive.batteryLevelAtEnd = UIDevice.current.batteryLevel
        
        // Log the end decision
        let stoppedDuration = stoppedSince.map { Date().timeIntervalSince($0) } ?? 0
        let endSpeedMS: Double
        if let location = currentLocation {
            endSpeedMS = computeSpeed(for: location)
        } else {
            endSpeedMS = 0
        }
        let decision = DriveDecision.driveEnded(
            reason: endReason,
            stationaryDuration: stoppedDuration,
            speed: endSpeedMS
        )
        driveLogger.logDecision(decision)
        
        // Detach logger before finalization
        driveLogger.detach()
        
        drive.finalize()
        
        // Send end notification with stats
        NotificationService.shared.sendDriveEnded(
            distance: drive.formattedDistance,
            duration: drive.formattedDuration
        )
        
        do {
            try modelContext?.save()
            logger.info("Finalized drive: \(drive.shortId), distance: \(drive.formattedDistance), duration: \(drive.formattedDuration)")
            
            // Notify listeners (e.g. SyncService)
            NotificationCenter.default.post(
                name: .driveEnded,
                object: nil,
                userInfo: [NotificationKeys.driveId: drive.id.uuidString]
            )
            
        } catch {
            logger.error("Failed to save drive: \(error.localizedDescription)")
        }
        pointsSinceLastSave = 0
        hasRecordedFirstFix = false
    }
    
    /// Periodically save drive data to prevent loss on crash
    private func periodicallySaveIfNeeded() {
        pointsSinceLastSave += 1
        
        guard pointsSinceLastSave >= saveInterval else { return }
        
        do {
            try modelContext?.save()
            logger.debug("Periodic save completed (\(self.pointsSinceLastSave) points)")
            pointsSinceLastSave = 0
        } catch {
            logger.error("Periodic save failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Cold Start Recovery
    
    /// Pending drive that needs validation by recoverFromColdStart().
    /// Set by recoverState() when it cannot definitively end a drive.
    private(set) var pendingRecoveryDrive: Drive?
    
    /// Recover state from persisted Drive after app launch.
    ///
    /// INVARIANT: recoverState() may only END drives — never RESUME them.
    ///
    /// This function handles clear-cut cases where we can definitively end a drive:
    /// - Drive age exceeds safety limit (8 hours)
    /// - stoppedSince exists and elapsed time exceeds timeout
    /// - Stopped at a saved place for extended period
    ///
    /// Ambiguous cases are deferred to recoverFromColdStart() which has access
    /// to real-time motion evidence to make the resume/end decision.
    private func recoverState() {
        guard let modelContext else { return }
        
        // Find any active drives (no endTime)
        let descriptor = FetchDescriptor<Drive>(
            predicate: #Predicate { $0.endTime == nil },
            sortBy: [SortDescriptor(\.startTime, order: .reverse)]
        )
        
        do {
            let activeDrives = try modelContext.fetch(descriptor)
            
            guard let lastActive = activeDrives.first else {
                logger.info("[RECOVERY] No unended drives found → idle")
                return
            }
            
            let driveAge = Date().timeIntervalSince(lastActive.startTime)
            let ageHours = driveAge / 3600
            let ageMinutes = driveAge / 60
            
            // Log recovery context for debugging
            logger.info("[RECOVERY] Found unended drive \(lastActive.shortId): age=\(String(format: "%.1f", ageMinutes))min, stoppedSince=\(lastActive.stoppedSince?.description ?? "nil"), points=\(lastActive.points.count)")
            
            // Normalize points ordering for any future use
            if lastActive.points.count > 1 {
                lastActive.points = lastActive.pointsChronological
            }
            
            // --- Clear-cut case 1: Safety limit exceeded ---
            if ageHours > safetyMaxDriveHours {
                logger.warning("[RECOVERY] DECISION: End drive \(lastActive.shortId) — age \(String(format: "%.1f", ageHours))h exceeds safety limit \(self.safetyMaxDriveHours)h")
                lastActive.finalize(endReason: .safetyTimeout)
                try modelContext.save()
                return
            }
            
            // --- Clear-cut case 2: Was stopped and timeout exceeded ---
            if let stoppedSince = lastActive.stoppedSince {
                let stoppedDuration = Date().timeIntervalSince(stoppedSince)
                let stoppedMinutes = stoppedDuration / 60
                
                logger.info("[RECOVERY] Drive was in stopped state since \(stoppedSince) (\(String(format: "%.1f", stoppedMinutes))min ago, timeout=\(self.stoppedTimeoutMinutes)min)")
                
                if stoppedDuration >= stoppedTimeoutSeconds {
                    logger.warning("[RECOVERY] DECISION: End drive \(lastActive.shortId) — stopped \(String(format: "%.1f", stoppedMinutes))min exceeds timeout \(self.stoppedTimeoutMinutes)min")
                    lastActive.finalize(endReason: .inactivityTimeout)
                    try modelContext.save()
                    return
                } else {
                    logger.info("[RECOVERY] Stopped duration within timeout (\(String(format: "%.1f", stoppedMinutes))min < \(self.stoppedTimeoutMinutes)min) — deferring to motion")
                }
            }
            
            // --- Clear-cut case 3: At saved place for extended period ---
            if let lastPoint = lastActive.pointsChronological.last {
                let coord = CLLocationCoordinate2D(latitude: lastPoint.latitude, longitude: lastPoint.longitude)
                let lastPointAge = Date().timeIntervalSince(lastPoint.timestamp)
                let lastPointMinutes = lastPointAge / 60
                
                if let place = placeVisitManager.bestMatchingPlace(for: coord) {
                    logger.info("[RECOVERY] Last GPS at saved place '\(place.name)' (\(String(format: "%.1f", lastPointMinutes))min ago)")
                    
                    // If at a saved place for >5 min, very likely arrived
                    if lastPointAge > 300 {
                        logger.warning("[RECOVERY] DECISION: End drive \(lastActive.shortId) — at '\(place.name)' for \(String(format: "%.1f", lastPointMinutes))min (>5min threshold)")
                        lastActive.finalize(endReason: .visitArrival)
                        try modelContext.save()
                        return
                    } else {
                        logger.info("[RECOVERY] At saved place but only \(String(format: "%.1f", lastPointMinutes))min (<5min) — deferring to motion")
                    }
                }
            }
            
            // --- Ambiguous case: Defer to recoverFromColdStart() ---
            // DO NOT set state = .driving here (invariant: recoverState only ends, never resumes)
            logger.info("[RECOVERY] DECISION: Defer drive \(lastActive.shortId) to motion validation — no clear-cut end condition met")
            pendingRecoveryDrive = lastActive
            
        } catch {
            logger.error("[RECOVERY] Failed to recover state: \(error.localizedDescription)")
        }
    }
}
