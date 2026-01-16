//
//  Life247App.swift
//  Life247
//
//  Created by Andrew Robertson on 1/14/26.
//

import SwiftUI
import SwiftData
import OSLog
import UIKit

@main
struct Life247App: App {
    
    private let logger = Logger(subsystem: "com.life247", category: "App")
    
    // MARK: - SwiftData
    
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Drive.self,
            LocationPoint.self,
            Place.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()
    
    // MARK: - Services
    
    @State private var stateMachine = DriveStateMachine()
    @StateObject private var locationManager = LocationManager()
    @StateObject private var motionManager = MotionManager()
    
    /// Track if setup has run (exactly once per process)
    @State private var hasSetup = false
    
    var body: some Scene {
        WindowGroup {
            ContentView(
                stateMachine: stateMachine,
                locationManager: locationManager,
                motionManager: motionManager
            )
            .onAppear {
                performSetupOnce()
            }
        }
        .modelContainer(sharedModelContainer)
    }
    
    // MARK: - Setup (Runs Exactly Once Per Process)
    
    @MainActor
    private func performSetupOnce() {
        guard !hasSetup else { return }
        hasSetup = true
        
        logger.info("[COLDSTART] App launched - beginning setup")
        
        // Initialize memory warning handler
        _ = MemoryManager.shared
        
        // Configure state machine with model context
        let context = sharedModelContainer.mainContext
        stateMachine.configure(modelContext: context)
        
        // Wire up event sinks
        locationManager.setEventSink(stateMachine)
        motionManager.setEventSink(stateMachine)
        
        // Start services if authorized
        if locationManager.hasAlwaysAuthorization {
            locationManager.startMonitoring()
        }
        
        if MotionManager.isAvailable {
            motionManager.startMonitoring()
        }
        
        // Wire up Airplane Mode reconciliation callback
        let sm = stateMachine
        AirplaneModeManager.shared.onDisable = {
            Task { @MainActor in
                sm.reconcileAfterPause()
            }
        }
        
        // Trigger cold-start recovery
        performColdStartRecovery()
    }
    
    // MARK: - Cold-Start Recovery
    
    @MainActor
    private func performColdStartRecovery() {
        // Airplane Mode: abort before starting any background work
        guard !AirplaneModeManager.shared.isEnabled else {
            logger.info("[AIRPLANE] Cold-start recovery suppressed - yielding to iOS")
            return
        }
        
        // Request background execution time for recovery
        var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "ColdStartRecovery") {
            // Cleanup if time expires
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
        
        logger.info("[COLDSTART] Querying motion history (last 10 minutes)")
        
        Task {
            // Query motion history - was user driving recently?
            let lookbackInterval: TimeInterval = 600 // 10 minutes
            let since = Date().addingTimeInterval(-lookbackInterval)
            
            let motionSuggestsDriving = await motionManager.wasAutomotiveRecently(since: since)
            
            // Get last known location if available
            let lastLocation = stateMachine.currentLocation
            
            // Perform recovery decision
            await MainActor.run {
                stateMachine.recoverFromColdStart(
                    motionSuggestsDriving: motionSuggestsDriving,
                    lastLocation: lastLocation
                )
                
                // Enable high-accuracy if we're now tracking
                if stateMachine.state == .driving || stateMachine.state == .maybeDriving {
                    locationManager.enableHighAccuracyMode()
                }
                
                logger.info("[COLDSTART] Recovery complete - state: \(stateMachine.state.rawValue)")
            }
            
            // End background task
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
            }
        }
    }
}

// MARK: - DriveStateMachine + LocationEventSink

extension DriveStateMachine: LocationEventSink {
    // The handle(_:) method is already implemented in DriveStateMachine
}
