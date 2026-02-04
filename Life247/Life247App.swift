//
//  Life247App.swift
//  Life247
//
//  Created by Andrew Robertson on 1/14/26.
//

import SwiftUI
import SwiftData
import CoreLocation
import OSLog
import UIKit

@main
struct Life247App: App {
    
    private let logger = Logger(subsystem: "com.life247", category: "App")
    @Environment(\.scenePhase) private var scenePhase
    
    // MARK: - SwiftData
    
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Drive.self,
            LocationPoint.self,
            Place.self,
            DriveLogEntry.self,
            PlaceVisit.self,
            AccelerationEvent.self,
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
    @StateObject private var syncService = DriveSyncService()
    @StateObject private var locationFilter = LocationFilter()
    
    /// Track if setup has run (exactly once per process)
    @State private var hasSetup = false
    
    var body: some Scene {
        WindowGroup {
            ContentView(
                stateMachine: stateMachine,
                locationManager: locationManager,
                motionManager: motionManager
            )
            .environmentObject(syncService)
            .onAppear {
                performSetupOnce()
            }
            .onChange(of: scenePhase) { _, newPhase in
                let stateName: String
                switch newPhase {
                case .active: stateName = "active"
                case .background: stateName = "background"
                case .inactive: stateName = "inactive"
                @unknown default: stateName = "unknown"
                }
                stateMachine.handleAppStateChange(stateName)
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
        
        // IMPORTANT: Wire up motion manager and accelerometer FIRST
        // This must happen before location events can trigger drives,
        // otherwise motionManager?.startAccelerometer() will silently fail.
        stateMachine.setMotionManager(motionManager)
        motionManager.setEventSink(stateMachine)
        locationManager.setMotionManager(motionManager)
        
        // Wire up accelerometer event handler to state machine (thread-safe hop to MainActor)
        // Note: Capture strong reference because [weak stateMachine] doesn't work with @State wrappers
        let sm = stateMachine
        motionManager.accelerationDetector.onEventDetected = { event in
            Task { @MainActor in
                sm.handleAccelerationEvent(event)
            }
        }
        
        // Wire up event sinks for location (after motion is ready)
        // Location events: LocationManager → LocationFilter → DriveStateMachine
        locationFilter.setEventSink(stateMachine)
        locationManager.setLocationFilter(locationFilter)
        locationManager.setEventSink(stateMachine)  // For non-location events (geofence, visits)
        stateMachine.setLocationManager(locationManager)

        
        // Start services if authorized
        if locationManager.hasAlwaysAuthorization {
            locationManager.startMonitoring()
            fixDuplicatePlaceIds()  // Fix migration issue where all places got same UUID
            syncGeofences()
        }
        
        if MotionManager.isAvailable {
            motionManager.startMonitoring()
        }
        
        // Wire up Airplane Mode reconciliation callback
        // (reuses 'sm' captured above for accelerometer handler)
        AirplaneModeManager.shared.onDisable = {
            Task { @MainActor in
                // Resume monitoring when Airplane Mode acts as "Unpause"
                if locationManager.hasAlwaysAuthorization {
                    locationManager.startMonitoring()
                }
                sm.reconcileAfterPause()
            }
        }
        
        AirplaneModeManager.shared.onEnable = {
            Task { @MainActor in
                // Stop monitoring immediately to save battery/privacy
                locationManager.stopMonitoring()
            }
        }
        
        // Start sync service
        syncService.start(container: sharedModelContainer)
        
        // Migrate existing drives (one-time operation)
        Task {
            await DriveMigrationHelper.migrateIfNeeded(modelContext: context)
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
        
        // Check if we have a pending drive that needs validation
        let hasPendingDrive = stateMachine.pendingRecoveryDrive != nil
        
        Task {
            // Query motion history - was user driving recently?
            let lookbackInterval: TimeInterval = 600 // 10 minutes
            let since = Date().addingTimeInterval(-lookbackInterval)
            
            // Use a lower threshold when we have a pending drive to bias toward resume.
            // The drive was already confirmed to be active, so we don't need as much evidence.
            let confidenceThreshold = hasPendingDrive ? 0.3 : 0.6
            let motionSuggestsDriving = await motionManager.wasAutomotiveRecently(
                since: since,
                confidenceThreshold: confidenceThreshold
            )
            
            logger.info("[COLDSTART] Motion query result: \\(motionSuggestsDriving) (threshold: \\(confidenceThreshold))")
            
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
                    locationManager.enableHighAccuracy(reason: "coldStart")
                }
                
                logger.info("[COLDSTART] Recovery complete - state: \\(stateMachine.state.rawValue)")
            }
            
            // End background task
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
            }
        }
    }

    
    // MARK: - Geofence Sync
    
    /// Key to track one-time geofence migration (entry notifications + UUID identifiers)
    /// V2: Force refresh to ensure all regions have notifyOnEntry = true after arrival fix
    private static let geofenceMigrationKey = "Life247.GeofenceMigrationV2Complete"
    private static let placeIdFixKey = "Life247.PlaceIdDuplicateFixComplete"
    
    /// One-time fix for migration issue where all places got the same UUID
    @MainActor
    private func fixDuplicatePlaceIds() {
        guard !UserDefaults.standard.bool(forKey: Self.placeIdFixKey) else { return }
        
        let context = sharedModelContainer.mainContext
        let descriptor = FetchDescriptor<Place>()
        
        do {
            let places = try context.fetch(descriptor)
            
            // Check for duplicates
            var seenIds = Set<UUID>()
            var needsFix = false
            
            for place in places {
                if seenIds.contains(place.placeId) {
                    needsFix = true
                    break
                }
                seenIds.insert(place.placeId)
            }
            
            if needsFix {
                logger.warning("[MIGRATION] Found duplicate placeIds - regenerating unique UUIDs")
                for place in places {
                    place.placeId = UUID()
                    logger.info("[MIGRATION] Assigned new UUID to '\(place.name)': \(place.placeId.uuidString)")
                }
                try context.save()
                logger.info("[MIGRATION] Place IDs fixed successfully")
                
                // Reset geofence migration so it re-syncs with new UUIDs
                UserDefaults.standard.set(false, forKey: Self.geofenceMigrationKey)
            }
            
            UserDefaults.standard.set(true, forKey: Self.placeIdFixKey)
        } catch {
            logger.error("[MIGRATION] Failed to fix duplicate place IDs: \(error.localizedDescription)")
        }
    }
    
    @MainActor
    private func syncGeofences() {
        guard locationManager.hasAlwaysAuthorization else { return }
        
        // Check if we need to force refresh (one-time migration to add entry notifications)
        let needsMigration = !UserDefaults.standard.bool(forKey: Self.geofenceMigrationKey)
        
        // Fetch all places
        let context = sharedModelContainer.mainContext
        let descriptor = FetchDescriptor<Place>()
        
        do {
            let places = try context.fetch(descriptor)
            let regions = places.map { place in
                CLCircularRegion(
                    center: place.coordinate,
                    radius: max(50, place.radiusMeters), // Ensure min radius
                    identifier: place.placeId.uuidString  // Use UUID to avoid duplicate name issues
                )
            }
            
            if needsMigration {
                logger.info("Performing one-time geofence migration (entry notifications + UUIDs)")
            }
            logger.info("Syncing \(regions.count) geofences from Saved Places")
            
            locationManager.updateMonitoredRegions(regions, forceRefresh: needsMigration)
            
            // Mark migration complete
            if needsMigration {
                UserDefaults.standard.set(true, forKey: Self.geofenceMigrationKey)
                logger.info("Geofence migration complete")
            }
        } catch {
            logger.error("Failed to fetch places for geofencing: \(error.localizedDescription)")
        }
    }
}

// MARK: - DriveStateMachine + LocationEventSink

extension DriveStateMachine: LocationEventSink {
    // The handle(_:) method is already implemented in DriveStateMachine
}
