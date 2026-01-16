//
//  MotionManager.swift
//  Life247
//
//  Created by Andrew Robertson on 1/14/26.
//

import Foundation
import CoreMotion
import Combine
import OSLog

/// Passive motion activity provider.
/// Responsibilities: Start/stop CMMotionActivity updates, convert to DriveEvents.
/// Forbidden: Driving inference, timers, persistence.
final class MotionManager: ObservableObject {
    
    // MARK: - Published State
    
    @Published private(set) var isAuthorized: Bool = false
    @Published private(set) var isMonitoring: Bool = false
    @Published private(set) var currentActivity: CMMotionActivity?
    
    // MARK: - Private Properties
    
    private let motionActivityManager = CMMotionActivityManager()
    private let logger = Logger(subsystem: "com.life247", category: "MotionManager")
    private weak var eventSink: LocationEventSink?
    private let operationQueue = OperationQueue()
    
    // MARK: - Initialization
    
    init() {
        operationQueue.name = "com.life247.motion"
        operationQueue.maxConcurrentOperationCount = 1
        checkAuthorization()
    }
    
    /// Set the event sink for motion events
    func setEventSink(_ sink: LocationEventSink) {
        self.eventSink = sink
    }
    
    // MARK: - Authorization
    
    /// Check if motion activity is available and authorized
    func checkAuthorization() {
        guard CMMotionActivityManager.isActivityAvailable() else {
            logger.warning("Motion activity not available on this device")
            isAuthorized = false
            return
        }
        
        // Authorization is checked implicitly when we start updates
        isAuthorized = true
    }
    
    /// Check if motion activity is available
    static var isAvailable: Bool {
        CMMotionActivityManager.isActivityAvailable()
    }
    
    // MARK: - Monitoring Control
    
    /// Start monitoring motion activity
    func startMonitoring() {
        guard CMMotionActivityManager.isActivityAvailable() else {
            logger.warning("Cannot start - motion activity not available")
            return
        }
        
        guard !isMonitoring else {
            logger.debug("Already monitoring motion")
            return
        }
        
        logger.info("Starting motion activity updates")
        
        motionActivityManager.startActivityUpdates(to: operationQueue) { [weak self] activity in
            guard let self, let activity else { return }
            
            Task { @MainActor in
                self.handleActivity(activity)
            }
        }
        
        isMonitoring = true
    }
    
    /// Stop monitoring motion activity
    func stopMonitoring() {
        guard isMonitoring else { return }
        
        logger.info("Stopping motion activity updates")
        motionActivityManager.stopActivityUpdates()
        isMonitoring = false
    }
    
    // MARK: - Activity Handling
    
    // Track last emitted activity category to deduplicate events
    private enum ActivityCategory {
        case none
        case automotive (confidence: CMMotionActivityConfidence)
        case nonAutomotive
    }
    private var lastEmittedCategory: ActivityCategory = .none

    private func handleActivity(_ activity: CMMotionActivity) {
        currentActivity = activity
        
        // Only process activities with reasonable confidence
        guard activity.confidence != .low else {
            // Log removed to reduce noise
            return
        }
        
        if activity.automotive {
            // Deduplicate: If we were already automotive with same confidence, skip
            if case .automotive(let lastConf) = lastEmittedCategory, lastConf == activity.confidence {
                return
            }
            
            logger.debug("Automotive activity detected (confidence: \(activity.confidence.rawValue))")
            eventSink?.handle(.motionAutomotive(confidence: activity.confidence))
            lastEmittedCategory = .automotive(confidence: activity.confidence)
            
        } else if activity.stationary || activity.walking || activity.running || activity.cycling {
            // Deduplicate: If we were already non-automotive, skip
            if case .nonAutomotive = lastEmittedCategory {
                return
            }
            
            logger.debug("Non-automotive activity detected")
            eventSink?.handle(.motionNotAutomotive)
            lastEmittedCategory = .nonAutomotive
        }
        // Unknown activity is ignored
    }
    
    // MARK: - Debug Info
    
    /// Last known meaningful activity (filters out Unknown)
    private var lastKnownDescription: String = "Stationary"
    
    /// Current activity description for UI - persists last known state
    var activityDescription: String {
        guard let activity = currentActivity else { return lastKnownDescription }
        
        let description: String
        if activity.automotive { 
            description = "Driving" 
        } else if activity.walking { 
            description = "Walking" 
        } else if activity.running { 
            description = "Running" 
        } else if activity.cycling { 
            description = "Cycling" 
        } else if activity.stationary { 
            description = "Stationary" 
        } else {
            // Unknown - return last known instead
            return lastKnownDescription
        }
        
        // Update last known
        lastKnownDescription = description
        return description
    }
    
    // MARK: - Historical Activity Oracle
    
    /// Query recent motion history to determine if user was likely driving.
    /// Pure oracle function - no side effects, no state mutation.
    /// - Parameters:
    ///   - since: How far back to look
    ///   - confidenceThreshold: Minimum confidence ratio (0.0-1.0) to consider automotive
    /// - Returns: True if automotive activity detected with sufficient confidence
    func wasAutomotiveRecently(
        since: Date,
        confidenceThreshold: Double = 0.6
    ) async -> Bool {
        guard CMMotionActivityManager.isActivityAvailable() else {
            logger.warning("[MOTION-HISTORY] Motion activity not available")
            return false
        }
        
        return await withCheckedContinuation { continuation in
            motionActivityManager.queryActivityStarting(
                from: since,
                to: Date(),
                to: operationQueue
            ) { [weak self] activities, error in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }
                
                if let error {
                    self.logger.error("[MOTION-HISTORY] Query failed: \(error.localizedDescription)")
                    continuation.resume(returning: false)
                    return
                }
                
                guard let activities, !activities.isEmpty else {
                    self.logger.info("[MOTION-HISTORY] No activities found in range")
                    continuation.resume(returning: false)
                    return
                }
                
                // Count automotive activities with medium or high confidence
                let automotiveCount = activities.filter { 
                    $0.automotive && $0.confidence != .low 
                }.count
                
                let totalWithConfidence = activities.filter { 
                    $0.confidence != .low 
                }.count
                
                guard totalWithConfidence > 0 else {
                    self.logger.info("[MOTION-HISTORY] No confident activities")
                    continuation.resume(returning: false)
                    return
                }
                
                let automotiveRatio = Double(automotiveCount) / Double(totalWithConfidence)
                let wasAutomotive = automotiveRatio >= confidenceThreshold
                
                self.logger.info("[MOTION-HISTORY] Automotive ratio: \(String(format: "%.2f", automotiveRatio)) (threshold: \(confidenceThreshold)) → \(wasAutomotive ? "YES" : "NO")")
                
                continuation.resume(returning: wasAutomotive)
            }
        }
    }
}
