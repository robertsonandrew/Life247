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
            .environmentObject(locationManager)
            .onAppear {
                performSetupOnce()
            }
            .task {
                performSetupOnce()
            }
            .onChange(of: scenePhase) { _, newPhase in
                performSetupOnce()

                let stateName: String
                switch newPhase {
                case .active: stateName = "active"
                case .background: stateName = "background"
                case .inactive: stateName = "inactive"
                @unknown default: stateName = "unknown"
                }
                stateMachine.handleAppStateChange(stateName)

                if newPhase == .active {
                    syncGeofences()
                }
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
        fixDuplicatePlaceIds()   // Legacy UUID migration guard
        cleanupDuplicatePlaces() // One-time physical dedupe migration
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
            syncGeofences()
        }
        
        if MotionManager.isAvailable {
            motionManager.startMonitoring()
        }

        // Keep notification settings and authorization in sync.
        // Defaults are ON, so proactively request permission once at startup.
        Task {
            let notifications = NotificationService.shared
            guard notifications.notifyOnStart || notifications.notifyOnEnd else { return }
            let granted = await notifications.requestPermissionIfNeeded()
            if !granted {
                await MainActor.run {
                    notifications.notifyOnStart = false
                    notifications.notifyOnEnd = false
                }
                logger.warning("Notification permission unavailable - drive notifications disabled")
            }
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
            
            logger.info("[COLDSTART] Motion query result: \(motionSuggestsDriving) (threshold: \(confidenceThreshold))")
            
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
                
                logger.info("[COLDSTART] Recovery complete - state: \(stateMachine.state.rawValue)")
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
    private static let placeIdFixKey = "Life247.PlaceIdDuplicateFixV2Complete"
    private static let placeCleanupKey = "Life247.PlaceDuplicateCleanupV2Complete"
    
    /// One-time fix for migration issue where all places got the same UUID
    @MainActor
    private func fixDuplicatePlaceIds() {
        guard !UserDefaults.standard.bool(forKey: Self.placeIdFixKey) else { return }
        
        let context = sharedModelContainer.mainContext
        let descriptor = FetchDescriptor<Place>()
        
        do {
            let places = try context.fetch(descriptor)
            
            let duplicateGroups = Dictionary(grouping: places, by: \.placeId)
                .filter { $0.value.count > 1 }

            if !duplicateGroups.isEmpty {
                var changedCount = 0
                logger.warning("[MIGRATION] Found \(duplicateGroups.count) duplicate placeId groups - repairing safely")

                for (_, group) in duplicateGroups {
                    let canonical = canonicalPlace(from: group)
                    for duplicate in group where duplicate.id != canonical.id {
                        let oldId = duplicate.placeId
                        duplicate.placeId = UUID()
                        changedCount += 1
                        logger.warning("[MIGRATION] Reassigned duplicate placeId for '\(duplicate.name)' \(oldId.uuidString) -> \(duplicate.placeId.uuidString)")
                    }
                }

                try context.save()
                logger.info("[MIGRATION] Place IDs repaired (\(changedCount) reassigned, canonical IDs preserved)")
                
                // Reset geofence migration so it re-syncs with new UUIDs
                UserDefaults.standard.set(false, forKey: Self.geofenceMigrationKey)
            }
            
            UserDefaults.standard.set(true, forKey: Self.placeIdFixKey)
        } catch {
            logger.error("[MIGRATION] Failed to fix duplicate place IDs: \(error.localizedDescription)")
        }
    }

    /// One-time migration to audit duplicate places created by prior bugs/sync drift.
    /// Non-destructive by design: duplicates are never deleted automatically.
    @MainActor
    private func cleanupDuplicatePlaces() {
        guard !UserDefaults.standard.bool(forKey: Self.placeCleanupKey) else { return }

        let context = sharedModelContainer.mainContext

        do {
            let places = try context.fetch(FetchDescriptor<Place>())
            guard places.count > 1 else {
                UserDefaults.standard.set(true, forKey: Self.placeCleanupKey)
                return
            }

            let clusters = duplicatePlaceClusters(from: places)
            var normalizedRadiusCount = 0
            for place in places {
                let clamped = place.clampedRadiusMeters
                if abs(place.radiusMeters - clamped) > 0.001 {
                    place.radiusMeters = clamped
                    normalizedRadiusCount += 1
                }
            }

            if normalizedRadiusCount > 0 {
                try context.save()
                UserDefaults.standard.set(false, forKey: Self.geofenceMigrationKey)
                logger.warning("[MIGRATION] Normalized \(normalizedRadiusCount) out-of-range place radii")
            }

            if clusters.isEmpty {
                logger.info("[MIGRATION] No duplicate places detected")
            } else {
                logger.warning("[MIGRATION] Duplicate place clusters detected (\(clusters.count)); leaving records intact (non-destructive)")
                for cluster in clusters {
                    let canonical = canonicalPlace(from: cluster)
                    let duplicateIds = cluster
                        .filter { $0.id != canonical.id }
                        .map(\.placeId.uuidString)
                        .joined(separator: ",")
                    logger.warning("[MIGRATION] Duplicate cluster '\(canonical.name)' canonical=\(canonical.placeId.uuidString) duplicates=[\(duplicateIds)]")
                }
                UserDefaults.standard.set(false, forKey: Self.geofenceMigrationKey)
            }

            UserDefaults.standard.set(true, forKey: Self.placeCleanupKey)
        } catch {
            logger.error("[MIGRATION] Failed duplicate place cleanup: \(error.localizedDescription)")
        }
    }

    private func duplicatePlaceClusters(from places: [Place]) -> [[Place]] {
        let proximityThresholdMeters: CLLocationDistance = 35
        let byName = Dictionary(grouping: places) { normalizePlaceName($0.name) }
        var clusters: [[Place]] = []

        for (_, sameNamePlaces) in byName {
            var nameClusters: [[Place]] = []
            for place in sameNamePlaces {
                if let idx = nameClusters.firstIndex(where: { cluster in
                    cluster.contains { candidate in
                        candidate.distance(to: place.coordinate) <= proximityThresholdMeters
                    }
                }) {
                    nameClusters[idx].append(place)
                } else {
                    nameClusters.append([place])
                }
            }
            clusters.append(contentsOf: nameClusters.filter { $0.count > 1 })
        }

        return clusters
    }

    private func canonicalPlace(from cluster: [Place]) -> Place {
        let centroid = clusterCentroidCoordinate(cluster)
        return cluster.min { lhs, rhs in
            if abs(lhs.effectiveRadius - rhs.effectiveRadius) > 0.5 {
                return lhs.effectiveRadius < rhs.effectiveRadius
            }
            let lhsDistance = lhs.distance(to: centroid)
            let rhsDistance = rhs.distance(to: centroid)
            if abs(lhsDistance - rhsDistance) > 0.5 {
                return lhsDistance < rhsDistance
            }
            return lhs.placeId.uuidString < rhs.placeId.uuidString
        } ?? cluster[0]
    }

    private func clusterCentroidCoordinate(_ cluster: [Place]) -> CLLocationCoordinate2D {
        let count = Double(max(cluster.count, 1))
        let lat = cluster.reduce(0.0) { $0 + $1.latitude } / count
        let lon = cluster.reduce(0.0) { $0 + $1.longitude } / count
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private func normalizePlaceName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
            let visits = try context.fetch(FetchDescriptor<PlaceVisit>())
            let dedupedPlaces = deduplicatedPlacesForGeofencing(places)
            let prioritizedPlaces = prioritizedPlacesForMonitoring(
                dedupedPlaces,
                visits: visits,
                currentCoordinate: locationManager.currentCoordinate,
                limit: 20
            )
            let regions = prioritizedPlaces.map { place in
                let monitoringRadius = locationManager.monitoringRadius(forUserRadiusMeters: place.clampedRadiusMeters)
                return CLCircularRegion(
                    center: place.coordinate,
                    radius: monitoringRadius,
                    identifier: place.placeId.uuidString  // Use UUID to avoid duplicate name issues
                )
            }
            
            if needsMigration {
                logger.info("Performing one-time geofence migration (entry notifications + UUIDs)")
            }
            if dedupedPlaces.count != places.count {
                logger.warning("Deduped geofences from \(places.count) places to \(dedupedPlaces.count) unique entries")
            }
            if prioritizedPlaces.count != dedupedPlaces.count {
                logger.warning("Prioritized geofences to top \(prioritizedPlaces.count) of \(dedupedPlaces.count) places (iOS limit)")
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

    private func deduplicatedPlacesForGeofencing(_ places: [Place]) -> [Place] {
        guard places.count > 1 else { return places }

        let clusters = duplicatePlaceClusters(from: places)
        guard !clusters.isEmpty else { return places }

        var clusteredIds = Set<UUID>()
        var deduped: [Place] = []

        for cluster in clusters {
            let canonical = canonicalPlace(from: cluster)
            deduped.append(canonical)
            for place in cluster {
                clusteredIds.insert(place.placeId)
            }
        }

        for place in places where !clusteredIds.contains(place.placeId) {
            deduped.append(place)
        }

        return deduped
    }

    private struct PlaceVisitStats {
        var count: Int = 0
        var lastArrival: Date?
    }

    private func prioritizedPlacesForMonitoring(
        _ places: [Place],
        visits: [PlaceVisit],
        currentCoordinate: CLLocationCoordinate2D?,
        limit: Int
    ) -> [Place] {
        guard places.count > limit else { return places }

        var visitStatsByPlaceId: [UUID: PlaceVisitStats] = [:]
        for visit in visits {
            guard let placeId = visit.place?.placeId else { continue }
            var stats = visitStatsByPlaceId[placeId] ?? PlaceVisitStats()
            stats.count += 1
            if let last = stats.lastArrival {
                if visit.arrivalTime > last {
                    stats.lastArrival = visit.arrivalTime
                }
            } else {
                stats.lastArrival = visit.arrivalTime
            }
            visitStatsByPlaceId[placeId] = stats
        }

        let now = Date()
        let activeVisitPlaceIds = Set(visits.filter { $0.departureTime == nil }.compactMap { $0.place?.placeId })
        let pinnedPlaceIds = Set(places.compactMap { place in
            if isPinnedMonitoringPlace(
                place,
                stats: visitStatsByPlaceId[place.placeId],
                activeVisitPlaceIds: activeVisitPlaceIds,
                currentCoordinate: currentCoordinate,
                now: now
            ) {
                return place.placeId
            }
            return nil
        })

        let pinned = places.filter { pinnedPlaceIds.contains($0.placeId) }
        let ranked = places.filter { !pinnedPlaceIds.contains($0.placeId) }.sorted { lhs, rhs in
            let lhsScore = monitoringPriorityScore(
                for: lhs,
                stats: visitStatsByPlaceId[lhs.placeId],
                currentCoordinate: currentCoordinate,
                now: now
            )
            let rhsScore = monitoringPriorityScore(
                for: rhs,
                stats: visitStatsByPlaceId[rhs.placeId],
                currentCoordinate: currentCoordinate,
                now: now
            )
            if abs(lhsScore - rhsScore) > 0.0001 {
                return lhsScore > rhsScore
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        let sortedPinned = pinned.sorted { lhs, rhs in
            let lhsScore = monitoringPriorityScore(
                for: lhs,
                stats: visitStatsByPlaceId[lhs.placeId],
                currentCoordinate: currentCoordinate,
                now: now
            )
            let rhsScore = monitoringPriorityScore(
                for: rhs,
                stats: visitStatsByPlaceId[rhs.placeId],
                currentCoordinate: currentCoordinate,
                now: now
            )
            if abs(lhsScore - rhsScore) > 0.0001 {
                return lhsScore > rhsScore
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        if sortedPinned.count >= limit {
            return Array(sortedPinned.prefix(limit))
        }

        let remaining = limit - sortedPinned.count
        return sortedPinned + Array(ranked.prefix(remaining))
    }

    private func isPinnedMonitoringPlace(
        _ place: Place,
        stats: PlaceVisitStats?,
        activeVisitPlaceIds: Set<UUID>,
        currentCoordinate: CLLocationCoordinate2D?,
        now: Date
    ) -> Bool {
        let normalizedName = normalizePlaceName(place.name)
        if normalizedName == "home" || normalizedName == "work" {
            return true
        }

        if activeVisitPlaceIds.contains(place.placeId) {
            return true
        }

        if let currentCoordinate {
            let nearbyThreshold = max(120.0, min(450.0, place.clampedRadiusMeters * 3.5))
            if place.distance(to: currentCoordinate) <= nearbyThreshold {
                return true
            }
        }

        if let lastArrival = stats?.lastArrival,
           now.timeIntervalSince(lastArrival) <= 3 * 86_400 {
            return true
        }

        return false
    }

    private func monitoringPriorityScore(
        for place: Place,
        stats: PlaceVisitStats?,
        currentCoordinate: CLLocationCoordinate2D?,
        now: Date
    ) -> Double {
        let distanceScore: Double
        if let currentCoordinate {
            let distance = place.distance(to: currentCoordinate)
            let capped = min(distance, 50_000)
            distanceScore = 1.0 - (capped / 50_000)
        } else {
            distanceScore = 0.35
        }

        let visitCount = stats?.count ?? 0
        let frequencyScore: Double
        if visitCount > 0 {
            frequencyScore = min(1.0, log1p(Double(visitCount)) / log1p(12.0))
        } else {
            frequencyScore = 0.0
        }

        let recencyScore: Double
        if let last = stats?.lastArrival {
            let ageDays = max(0, now.timeIntervalSince(last) / 86_400)
            recencyScore = 1.0 - min(ageDays, 30.0) / 30.0
        } else {
            recencyScore = 0.0
        }

        return (distanceScore * 0.55) + (recencyScore * 0.25) + (frequencyScore * 0.20)
    }
}

// MARK: - DriveStateMachine + LocationEventSink

extension DriveStateMachine: LocationEventSink {
    // The handle(_:) method is already implemented in DriveStateMachine
}
