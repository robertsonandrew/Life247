//
//  PlaceVisitManager.swift
//  Life247
//
//  Created by Andrew Robertson on 1/20/26.
//

import Foundation
import CoreLocation
import CoreData
import SwiftData
import OSLog

/// Manages PlaceVisit lifecycle and dwell detection.
/// Extracted from DriveStateMachine to maintain single-responsibility.
@MainActor
@Observable
final class PlaceVisitManager {
    
    // MARK: - Public State
    
    /// Current active place visit (nil when not dwelling at a saved place)
    private(set) var activePlaceVisit: PlaceVisit?
    
    /// Summary of active dwell session for lightweight UI consumption
    struct ActiveDwellSummary {
        let placeId: UUID?
        let placeName: String
        let placeIcon: String
        let arrivalTime: Date
        let placeCoordinate: CLLocationCoordinate2D
        let placeRadiusMeters: Double
    }
    
    /// Current active dwell session (if any), suitable for lightweight UI.
    var activeDwellSummary: ActiveDwellSummary? {
        guard let activePlaceVisit, activePlaceVisit.departureTime == nil else { return nil }
        let linkedPlace = activePlaceVisit.place
        let snapshotCoordinate = CLLocationCoordinate2D(
            latitude: activePlaceVisit.placeLatitude,
            longitude: activePlaceVisit.placeLongitude
        )
        let snapshotRadius = min(Place.maxUserRadiusMeters, max(Place.minUserRadiusMeters, activePlaceVisit.placeRadiusMeters))

        return ActiveDwellSummary(
            placeId: linkedPlace?.placeId,
            placeName: activePlaceVisit.placeName,
            placeIcon: activePlaceVisit.placeIcon,
            arrivalTime: activePlaceVisit.arrivalTime,
            placeCoordinate: linkedPlace?.coordinate ?? snapshotCoordinate,
            placeRadiusMeters: linkedPlace?.clampedRadiusMeters ?? snapshotRadius
        )
    }
    
    // MARK: - Private State
    
    private var modelContext: ModelContext?
    private let logger = Logger(subsystem: "com.life247", category: "PlaceVisitManager")
    
    /// Cached places for efficient lookup - invalidated on place changes
    private var cachedPlaces: [Place]?
    private var placeCacheTime: Date?
    /// Cache TTL in seconds (places don't change frequently)
    private let placeCacheTTL: TimeInterval = 60.0
    
    // MARK: - Initialization
    
    init() {
        logger.info("PlaceVisitManager initialized")
        
        // Listen for place changes to invalidate cache
        NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.invalidatePlaceCache()
            }
        }
    }
    
    /// Configure with SwiftData model context
    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
        invalidatePlaceCache()
        recoverActivePlaceVisit()
    }
    
    /// Invalidate the place cache (call when places are added/removed/modified)
    func invalidatePlaceCache() {
        cachedPlaces = nil
        placeCacheTime = nil
    }
    
    /// Get all places, using cache when available
    private func getAllPlaces() -> [Place] {
        // Check if cache is valid
        if let cached = cachedPlaces,
           let cacheTime = placeCacheTime,
           Date().timeIntervalSince(cacheTime) < placeCacheTTL {
            return cached
        }
        
        // Fetch fresh data
        guard let modelContext else { return [] }
        guard let places = try? modelContext.fetch(FetchDescriptor<Place>()) else { return [] }
        
        // Update cache
        cachedPlaces = places
        placeCacheTime = Date()
        
        return places
    }
    
    // MARK: - Recovery
    
    /// Recover any active (non-departed) place visit on app launch
    private func recoverActivePlaceVisit() {
        guard let modelContext else { return }
        let descriptor = FetchDescriptor<PlaceVisit>(
            predicate: #Predicate { $0.departureTime == nil },
            sortBy: [SortDescriptor(\PlaceVisit.arrivalTime, order: .reverse)]
        )

        if let visit = try? modelContext.fetch(descriptor).first {
            activePlaceVisit = visit
            logger.info("Recovered active place visit at '\(visit.placeName)'")
        }
    }
    
    // MARK: - Place Matching
    
    /// Find the best matching saved Place for a coordinate (smallest containing place)
    /// Uses cached places for performance
    func bestMatchingPlace(for coordinate: CLLocationCoordinate2D) -> Place? {
        bestMatchingPlace(for: coordinate, additionalBufferMeters: 0)
    }

    /// Find the best matching saved Place for a location sample.
    /// Uses a small accuracy-derived buffer to reduce false negatives near place edges.
    func bestMatchingPlace(for location: CLLocation) -> Place? {
        let buffer = containmentBuffer(for: location.horizontalAccuracy)
        return bestMatchingPlace(for: location.coordinate, additionalBufferMeters: buffer)
    }

    private func bestMatchingPlace(
        for coordinate: CLLocationCoordinate2D,
        additionalBufferMeters: CLLocationDistance
    ) -> Place? {
        let places = getAllPlaces()
        guard !places.isEmpty else { return nil }

        let matches = places.filter { $0.contains(coordinate, additionalBufferMeters: additionalBufferMeters) }
        guard !matches.isEmpty else { return nil }

        return matches.min { lhs, rhs in
            let lhsRadius = lhs.effectiveRadius
            let rhsRadius = rhs.effectiveRadius
            if abs(lhsRadius - rhsRadius) > 0.5 {
                return lhsRadius < rhsRadius
            }
            return lhs.distance(to: coordinate) < rhs.distance(to: coordinate)
        }
    }

    private func containmentBuffer(for horizontalAccuracy: CLLocationAccuracy) -> CLLocationDistance {
        guard horizontalAccuracy > 0 else { return 0 }
        // Conservative buffer: enough to absorb normal jitter without making containment too loose.
        return min(60, max(0, horizontalAccuracy * 0.75))
    }

    /// Find a saved Place by geofence region identifier (UUID string).
    /// Uses cached places for performance.
    func place(for regionId: String) -> Place? {
        guard let placeUUID = UUID(uuidString: regionId) else { return nil }
        let places = getAllPlaces()
        return places.first { $0.placeId == placeUUID }
    }
    
    // MARK: - CLVisit-based Place Visits
    
    /// Start a PlaceVisit if the CLVisit coordinate matches a saved Place.
    func startPlaceVisitIfPossible(from visit: CLVisit) {
        guard let modelContext else { return }

        let coord = visit.coordinate
        guard coord.latitude != 0 || coord.longitude != 0 else { return }

        // If we already have an active visit and we're still within the same place, do nothing.
        if let active = activePlaceVisit,
           let place = active.place,
           place.contains(coord) {
            return
        }

        // Find best matching place.
        guard let place = bestMatchingPlace(for: coord) else { return }

        // Close any existing active visit (defensive)
        if let activePlaceVisit {
            activePlaceVisit.departureTime = Date()
        }

        let arrival = visit.arrivalDate == .distantPast ? Date() : visit.arrivalDate
        let newVisit = PlaceVisit(
            arrivalTime: arrival,
            coordinate: coord,
            place: place,
            source: "clvisit"
        )
        modelContext.insert(newVisit)
        activePlaceVisit = newVisit
        try? modelContext.save()
        
        logger.info("Started place visit at '\(place.name)' from CLVisit")
    }
    
    /// End the active PlaceVisit based on CLVisit departure
    func endActivePlaceVisitIfNeeded(from visit: CLVisit) {
        guard let modelContext else { return }
        guard let active = activePlaceVisit else { return }

        let departure = visit.departureDate == .distantFuture ? Date() : visit.departureDate
        active.departureTime = departure
        active.syncStatus = "pending"
        NotificationCenter.default.post(
            name: .placeVisitEnded,
            object: nil,
            userInfo: [NotificationKeys.placeVisitId: active.id.uuidString]
        )
        
        logger.info("Ended place visit at '\(active.placeName)' from CLVisit departure")
        activePlaceVisit = nil
        try? modelContext.save()
    }
    
    // MARK: - Location-based Dwell Detection
    
    /// Update dwell state based on current location (called when idle)
    func updateDwellIfNeeded(currentLocation: CLLocation) {
        guard let modelContext else { return }

        let coord = currentLocation.coordinate

        // Keep active visit alive if still inside.
        if let active = activePlaceVisit,
           let place = active.place,
           place.contains(coord) {
            return
        }

        // If we had an active visit but we're no longer inside its place, end it.
        if let active = activePlaceVisit,
           let place = active.place,
           !place.contains(coord) {
            active.departureTime = Date()
            active.syncStatus = "pending"
            NotificationCenter.default.post(
                name: .placeVisitEnded,
                object: nil,
                userInfo: [NotificationKeys.placeVisitId: active.id.uuidString]
            )
            logger.info("Ended place visit at '\(active.placeName)' - left place radius")
            activePlaceVisit = nil
            try? modelContext.save()
        }

        // Start a new visit if we're currently inside a place.
        guard let place = bestMatchingPlace(for: coord) else { return }
        let newVisit = PlaceVisit(
            arrivalTime: Date(),
            coordinate: coord,
            place: place,
            source: "location"
        )
        modelContext.insert(newVisit)
        activePlaceVisit = newVisit
        try? modelContext.save()
        
        logger.info("Started place visit at '\(place.name)' from location update")
    }
    
    // MARK: - State Machine Integration
    
    /// Start a place visit when arriving at a saved place while stopped (drive ending)
    /// Returns the created PlaceVisit if successful
    @discardableResult
    func startPlaceVisitForArrival(at coordinate: CLLocationCoordinate2D, place: Place) -> PlaceVisit? {
        guard let modelContext else { return nil }
        guard activePlaceVisit == nil else { return activePlaceVisit }
        
        let newVisit = PlaceVisit(
            arrivalTime: Date(),
            coordinate: coordinate,
            place: place,
            source: "stopped_arrival"
        )
        modelContext.insert(newVisit)
        activePlaceVisit = newVisit
        try? modelContext.save()
        
        logger.info("Started place visit at '\(place.name)' from stopped arrival")
        return newVisit
    }
    
    /// End the active place visit when starting to drive away
    func endActivePlaceVisitForDeparture() {
        guard let modelContext else { return }
        guard let active = activePlaceVisit else { return }
        
        active.departureTime = Date()
        active.syncStatus = "pending"
        NotificationCenter.default.post(
            name: .placeVisitEnded,
            object: nil,
            userInfo: [NotificationKeys.placeVisitId: active.id.uuidString]
        )
        
        logger.info("Ended place visit at '\(active.placeName)' - starting to drive")
        activePlaceVisit = nil
        try? modelContext.save()
    }
    
    /// Check if there's currently an active place visit
    var hasActivePlaceVisit: Bool {
        activePlaceVisit != nil
    }
}
