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

/// The single source of truth for drive state.
/// Only this class may start, stop, pause, or end a drive.
@MainActor
@Observable
final class DriveStateMachine {
    
    // MARK: - Constants (Tuneable Parameters)
    
    /// Speed threshold to trigger maybeDriving (mph)
    private let maybeDrivingSpeedThreshold: Double = 8.0
    
    /// Speed threshold to confirm driving (mph)
    private let drivingConfirmationSpeed: Double = 10.0
    
    /// Speed threshold to detect stopped (mph)
    private let stoppedSpeedThreshold: Double = 1.0
    
    /// Speed threshold to resume from stopped (mph)
    private let resumeSpeedThreshold: Double = 5.0
    
    /// Maximum drive duration before safety end (hours)
    private let safetyMaxDriveHours: Double = 8.0
    
    /// Minimum horizontal accuracy for valid GPS readings (meters)
    private let minAccuracy: Double = 65.0
    
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
    
    // MARK: - Published State
    
    /// Current drive state
    private(set) var state: DriveState = .idle
    
    /// Current active drive (nil when idle or maybeDriving)
    private(set) var activeDrive: Drive?
    
    /// Latest location for UI display
    private(set) var currentLocation: CLLocation?
    
    /// Current speed in MPH
    var currentSpeedMPH: Double {
        guard let speed = currentLocation?.speed, speed >= 0 else { return 0 }
        return speed * 2.23694
    }
    
    // MARK: - Private State
    
    private var modelContext: ModelContext?
    private let logger = Logger(subsystem: "com.life247", category: "StateMachine")
    
    // Timer management
    private var verificationTimer: Task<Void, Never>?
    private var stoppedTimer: Task<Void, Never>?
    private var safetyTimer: Task<Void, Never>?
    
    // Speed verification tracking
    private var sustainedHighSpeedStart: Date?
    private var sustainedLowSpeedStart: Date?
    
    // Stopped state tracking (for Issue #1 fix)
    private var stoppedSince: Date?
    
    // Periodic save tracking (for Issue #2 fix)
    private var pointsSinceLastSave: Int = 0
    private let saveInterval: Int = 50  // Save every 50 points
    
    // MARK: - Initialization
    
    init() {
        logger.info("DriveStateMachine initialized in idle state")
    }
    
    /// Configure with SwiftData model context
    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
        recoverState()
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
        
        // Check if we should end the drive based on current conditions
        let currentSpeed = currentLocation?.speed ?? 0
        let speedMPH = max(0, currentSpeed * 2.23694)
        
        // If speed is near zero, transition using normal logic
        if speedMPH < stoppedSpeedThreshold {
            logger.info("[RECONCILE] Speed is low (\(String(format: "%.1f", speedMPH))mph) - transitioning to stopped")
            
            if state == .driving {
                transition(to: .stopped)
            }
            
            // Start the stopped timer which will end the drive after timeout
            // (Timer was already started by transition to .stopped)
            
            // If we're already in .stopped, check if we've been stopped long enough to end
            if state == .stopped {
                let stoppedTimeout = stoppedTimeoutMinutes * 60
                let stoppedDuration = stoppedSince.map { Date().timeIntervalSince($0) } ?? 0
                
                // End drive if we've been in stopped state longer than timeout
                if stoppedDuration > stoppedTimeout {
                    logger.info("[RECONCILE] Stopped duration (\(Int(stoppedDuration))s) exceeds timeout - ending drive")
                    transition(to: .ended)
                } else {
                    logger.info("[RECONCILE] Stopped for \(Int(stoppedDuration))s, timeout is \(Int(stoppedTimeout))s - continuing")
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
        transition(to: .ended)
    }
    
    // MARK: - Cold-Start Recovery
    
    /// Speed threshold for cold-start confirmation (m/s) - ~15 mph
    private let coldStartSpeedThreshold: Double = 6.7
    
    /// Recover drive state after app launch (cold start).
    /// Decision table:
    /// - motion=false → Abort (stay idle)
    /// - motion=true + speed≥threshold → Enter `driving` directly
    /// - motion=true + speed unknown → Enter `maybeDriving`
    ///
    /// Invariant: Only this method may bypass normal state transitions for recovery.
    func recoverFromColdStart(
        motionSuggestsDriving: Bool,
        lastLocation: CLLocation?
    ) {
        // Airplane Mode: suppress cold-start recovery
        guard !AirplaneModeManager.shared.isEnabled else {
            logger.info("[AIRPLANE] Cold-start recovery suppressed")
            return
        }
        
        logger.info("[COLDSTART] Beginning recovery - motion=\(motionSuggestsDriving), hasLocation=\(lastLocation != nil)")
        
        // Only recover if currently idle
        guard self.state == .idle else {
            logger.info("[COLDSTART] Skipping - already in state: \(self.state.rawValue)")
            return
        }
        
        // Decision: No motion evidence → no recovery
        guard motionSuggestsDriving else {
            logger.info("[RECOVERY] Motion does not suggest driving → staying idle")
            return
        }
        
        // Update current location
        if let location = lastLocation {
            currentLocation = location
        }
        
        // Check speed if available
        let speed = lastLocation?.speed ?? -1
        let speedMPH = speed >= 0 ? speed * 2.23694 : -1
        
        if speed >= coldStartSpeedThreshold {
            // Motion + Speed confirmed → go directly to driving
            logger.info("[RECOVERY] Motion=YES, Speed=\(String(format: "%.1f", speedMPH))mph → entering DRIVING")
            
            // Skip maybeDriving - go directly to driving
            state = .driving
            createNewDrive()
            startSafetyTimer()
            
        } else if speed >= 0 && speed < coldStartSpeedThreshold {
            // Motion suggests driving but speed is low - maybe stopped at light
            logger.info("[RECOVERY] Motion=YES, Speed=\(String(format: "%.1f", speedMPH))mph (low) → entering DRIVING (may be stopped)")
            
            // Still enter driving - user was likely driving recently
            state = .driving
            createNewDrive()
            startSafetyTimer()
            
        } else {
            // Motion suggests driving but no speed data
            logger.info("[RECOVERY] Motion=YES, Speed=unknown → entering MAYBEDRIVING")
            transition(to: .maybeDriving)
        }
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
        
        logger.debug("Received event: \(String(describing: event)) in state: \(self.state.rawValue)")
        
        switch event {
        case .motionAutomotive(let confidence):
            handleMotionAutomotive(confidence: confidence)
            
        case .motionNotAutomotive:
            handleMotionNotAutomotive()
            
        case .locationUpdate(let location):
            handleLocationUpdate(location)
            
        case .significantLocationChange:
            handleSignificantLocationChange()
            
        case .visitArrival:
            handleVisitArrival()
            
        case .visitDeparture:
            handleVisitDeparture()
            
        case .timerExpired(let kind):
            handleTimerExpired(kind)
        }
    }
    
    // MARK: - Event Handlers
    
    private func handleMotionAutomotive(confidence: CMMotionActivityConfidence) {
        switch state {
        case .idle:
            // Motion alone can trigger maybeDriving
            if confidence == .high || confidence == .medium {
                transition(to: .maybeDriving)
            }
            
        case .maybeDriving, .driving, .stopped:
            // Motion supports current driving assessment but doesn't change state
            break
            
        case .ended:
            // Ignore - drive already finalized
            break
        }
    }
    
    private func handleMotionNotAutomotive() {
        switch state {
        case .maybeDriving:
            // Non-automotive motion negates maybeDriving
            transition(to: .idle)
            
        case .idle, .driving, .stopped, .ended:
            // Ignore - GPS is the authority during active driving
            break
        }
    }
    
    private func handleLocationUpdate(_ location: CLLocation) {
        // Update current location for UI
        currentLocation = location
        
        // Filter low-accuracy readings
        guard location.horizontalAccuracy <= minAccuracy else {
            logger.debug("Ignoring low-accuracy location: \(location.horizontalAccuracy)m")
            return
        }
        
        let speedMPH = max(0, location.speed * 2.23694)
        
        switch state {
        case .idle:
            // Speed alone can trigger maybeDriving
            if speedMPH >= maybeDrivingSpeedThreshold {
                transition(to: .maybeDriving)
            }
            
        case .maybeDriving:
            // Check for sustained high speed
            if speedMPH >= drivingConfirmationSpeed {
                if sustainedHighSpeedStart == nil {
                    sustainedHighSpeedStart = Date()
                } else if Date().timeIntervalSince(sustainedHighSpeedStart!) >= drivingConfirmationDuration {
                    transition(to: .driving)
                }
            } else {
                // Speed dropped, reset verification
                sustainedHighSpeedStart = nil
            }
            
        case .driving:
            // Record location point
            if activeDrive?.addPoint(location) == true {
                periodicallySaveIfNeeded()
            }
            
            // Check for low speed (potential stop)
            if speedMPH < stoppedSpeedThreshold {
                if sustainedLowSpeedStart == nil {
                    sustainedLowSpeedStart = Date()
                } else if Date().timeIntervalSince(sustainedLowSpeedStart!) >= stoppedDetectionDuration {
                    transition(to: .stopped)
                }
            } else {
                sustainedLowSpeedStart = nil
            }
            
        case .stopped:
            // Record location point (GPS still running)
            if activeDrive?.addPoint(location) == true {
                periodicallySaveIfNeeded()
            }
            
            // Check for resume
            if speedMPH >= resumeSpeedThreshold {
                transition(to: .driving)
            }
            
        case .ended:
            // Ignore - drive finalized
            break
        }
    }
    
    private func handleSignificantLocationChange() {
        // SLC is used to wake the app, not to infer driving
        // Just log for debugging
        logger.info("Significant location change received in state: \(self.state.rawValue)")
    }
    
    private func handleVisitArrival() {
        switch state {
        case .driving, .stopped:
            // Visit arrival indicates we've arrived somewhere - end the drive
            logger.info("Visit arrival detected - ending drive")
            transition(to: .ended)
            
        case .idle, .maybeDriving, .ended:
            break
        }
    }
    
    private func handleVisitDeparture() {
        switch state {
        case .idle:
            // Departing a location could indicate start of drive
            transition(to: .maybeDriving)
            
        case .maybeDriving, .driving, .stopped, .ended:
            break
        }
    }
    
    private func handleTimerExpired(_ kind: TimerKind) {
        logger.info("Timer expired: \(kind.rawValue) in state: \(self.state.rawValue)")
        
        switch kind {
        case .maybeDrivingVerification:
            if state == .maybeDriving {
                // Verification period expired without confirming drive
                transition(to: .idle)
            }
            
        case .stoppedTimeout:
            if state == .stopped {
                // Been stopped too long - end drive
                transition(to: .ended)
            }
            
        case .safetyEnd:
            if state == .driving || state == .stopped {
                // Safety limit reached - force end
                logger.warning("Safety timer expired - force ending drive")
                transition(to: .ended)
            }
        }
    }
    
    // MARK: - State Transitions
    
    private func transition(to newState: DriveState) {
        let oldState = state
        
        // Validate transition
        guard isValidTransition(from: oldState, to: newState) else {
            logger.error("Illegal transition attempted: \(oldState.rawValue) → \(newState.rawValue)")
            return
        }
        
        logger.info("Transition: \(oldState.rawValue) → \(newState.rawValue)")
        
        // Exit actions
        exitState(oldState)
        
        // Update state
        state = newState
        
        // Entry actions
        enterState(newState)
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
            
        // Illegal transitions
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
            
        case .stopped:
            stoppedTimer?.cancel()
            stoppedTimer = nil
            stoppedSince = nil
            
        case .driving:
            sustainedLowSpeedStart = nil
            
        case .idle, .ended:
            break
        }
    }
    
    private func enterState(_ state: DriveState) {
        switch state {
        case .idle:
            // Clean up any active drive reference (but don't delete)
            activeDrive = nil
            
        case .maybeDriving:
            // Start verification timer
            startVerificationTimer()
            
        case .driving:
            // Create new drive if needed
            if activeDrive == nil {
                createNewDrive()
                // Send notification (only on fresh drive start)
                NotificationService.shared.sendDriveStarted()
            }
            // Start safety timer
            startSafetyTimer()
            
        case .stopped:
            // Track when stopped started (for timeout calculation)
            stoppedSince = Date()
            // Start stopped timeout timer
            startStoppedTimer()
            
        case .ended:
            // Finalize drive
            finalizeDrive()
            // Cancel safety timer
            safetyTimer?.cancel()
            safetyTimer = nil
            // Move back to idle after a brief delay
            Task {
                try? await Task.sleep(for: .seconds(1))
                self.state = .idle
                self.activeDrive = nil
            }
        }
    }
    
    // MARK: - Timer Management
    
    private func startVerificationTimer() {
        verificationTimer = Task {
            try? await Task.sleep(for: .seconds(60)) // 1 minute to verify
            guard !Task.isCancelled else { return }
            handle(.timerExpired(.maybeDrivingVerification))
        }
    }
    
    private func startStoppedTimer() {
        stoppedTimer = Task {
            try? await Task.sleep(for: .seconds(stoppedTimeoutMinutes * 60))
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
    
    // MARK: - Persistence
    
    private func createNewDrive() {
        guard let modelContext else {
            logger.error("ModelContext not configured - cannot create drive")
            return
        }
        
        let drive = Drive(startTime: Date())
        
        // Add first point if we have a location
        if let location = currentLocation {
            drive.addPoint(location)
        }
        
        modelContext.insert(drive)
        activeDrive = drive
        pointsSinceLastSave = 0  // Reset save counter for new drive
        
        logger.info("Created new drive: \(drive.shortId)")
        logger.info("[SETTINGS] stoppedTimeout=\(Int(self.stoppedTimeoutMinutes))min stoppedDetection=\(Int(self.stoppedDetectionDuration))s drivingConfirm=\(Int(self.drivingConfirmationDuration))s")
    }
    
    private func finalizeDrive() {
        guard let drive = activeDrive else { return }
        
        drive.finalize()
        
        // Send end notification with stats
        NotificationService.shared.sendDriveEnded(
            distance: drive.formattedDistance,
            duration: drive.formattedDuration
        )
        
        do {
            try modelContext?.save()
            logger.info("Finalized drive: \(drive.shortId), distance: \(drive.formattedDistance), duration: \(drive.formattedDuration)")
        } catch {
            logger.error("Failed to save drive: \(error.localizedDescription)")
        }
        pointsSinceLastSave = 0  // Reset counter after final save
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
    
    private func recoverState() {
        guard let modelContext else { return }
        
        // Find any active drives (no endTime)
        let descriptor = FetchDescriptor<Drive>(
            predicate: #Predicate { $0.endTime == nil },
            sortBy: [SortDescriptor(\.startTime, order: .reverse)]
        )
        
        do {
            let activeDrives = try modelContext.fetch(descriptor)
            
            if let lastActive = activeDrives.first {
                // Check if it's stale (started more than safety limit ago)
                let ageHours = Date().timeIntervalSince(lastActive.startTime) / 3600
                
                if ageHours > safetyMaxDriveHours {
                    // Auto-end stale drive
                    logger.warning("Auto-ending stale drive: \(lastActive.shortId)")
                    lastActive.finalize()
                    try modelContext.save()
                } else {
                    // Resume active drive
                    logger.info("Recovering active drive: \(lastActive.shortId)")
                    activeDrive = lastActive
                    state = .driving
                    startSafetyTimer()
                }
            }
        } catch {
            logger.error("Failed to recover state: \(error.localizedDescription)")
        }
    }
}
