//
//  GeocodingCache.swift
//  Life247
//
//  Created by Andrew Robertson on 1/15/26.
//

import Foundation
import CoreLocation
import MapKit
import OSLog

/// Caches reverse geocoding results to avoid repeated lookups.
/// Keys are rounded coordinates (4 decimal places ≈ 11m precision).
/// Cache is persisted to disk to survive app restarts.
actor GeocodingCache {
    static let shared = GeocodingCache()
    
    private var cache: [String: String] = [:]
    private var insertionOrder: [String] = []  // Track key insertion order for LRU eviction
    private let maxEntries = 500
    private let logger = Logger(subsystem: "com.life247", category: "GeocodingCache")
    private var hasLoadedFromDisk = false
    
    // MARK: - In-flight Request Deduplication
    
    /// Track pending requests to avoid duplicate geocoding calls
    private var inFlightRequests: [String: Task<String?, Never>] = [:]
    
    // MARK: - Rate Limiting & Backoff
    
    /// Track when we were last rate-limited
    private var rateLimitedUntil: Date?
    
    /// Current backoff duration (exponential)
    private var currentBackoffSeconds: TimeInterval = 1.0
    
    /// Maximum backoff duration
    private let maxBackoffSeconds: TimeInterval = 60.0
    
    // MARK: - Negative Result Caching
    
    /// Coordinates where no placemark was found (avoid re-querying)
    private var notFoundCache: Set<String> = []
    
    /// Max negative cache entries before pruning
    private let maxNotFoundEntries = 200
    
    /// File URL for persisted cache
    private nonisolated var cacheFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let cacheDir = appSupport.appendingPathComponent("Life247", isDirectory: true)
        return cacheDir.appendingPathComponent("geocoding_cache.json")
    }
    
    private init() {
        // Disk loading is deferred to first access
    }
    
    /// Ensure cache is loaded from disk (called lazily)
    private func ensureLoaded() {
        guard !hasLoadedFromDisk else { return }
        hasLoadedFromDisk = true
        
        let fileURL = cacheFileURL
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            logger.info("No cache file found - starting fresh")
            return
        }
        
        do {
            let data = try Data(contentsOf: fileURL)
            let cacheData = try JSONDecoder().decode(CacheData.self, from: data)
            cache = cacheData.cache
            insertionOrder = cacheData.insertionOrder
            logger.info("Loaded \(self.cache.count) cached addresses from disk")
        } catch {
            logger.error("Failed to load cache from disk: \(error.localizedDescription)")
        }
    }
    
    /// Get cached address or perform reverse geocoding.
    func address(for coordinate: CLLocationCoordinate2D) async -> String? {
        ensureLoaded()
        
        let key = cacheKey(for: coordinate)
        
        // Check positive cache first
        if let cached = cache[key] {
            return cached
        }
        
        // Check negative cache (we already know nothing is there)
        if notFoundCache.contains(key) {
            return nil
        }
        
        // Check if we're rate-limited
        if let rateLimitedUntil, Date() < rateLimitedUntil {
            logger.debug("Skipping geocode for \(key) - rate limited until \(rateLimitedUntil)")
            return nil
        }
        
        // Check for in-flight request for same key
        if let existingTask = inFlightRequests[key] {
            logger.debug("Joining existing geocode request for \(key)")
            return await existingTask.value
        }
        
        // Create new geocoding task
        let task = Task<String?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.performGeocode(for: coordinate, key: key)
        }
        
        inFlightRequests[key] = task
        let result = await task.value
        inFlightRequests.removeValue(forKey: key)
        
        return result
    }
    
    /// Perform the actual geocoding request
    private func performGeocode(for coordinate: CLLocationCoordinate2D, key: String) async -> String? {
        // Reverse geocode using MapKit's MKLocalSearch as a point-of-interest lookup
        let searchRequest = MKLocalSearch.Request()
        searchRequest.region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 50,
            longitudinalMeters: 50
        )
        
        do {
            let search = MKLocalSearch(request: searchRequest)
            let response = try await search.start()
            
            // Reset backoff on success
            currentBackoffSeconds = 1.0
            rateLimitedUntil = nil
            
            if let mapItem = response.mapItems.first {
                let address = formatAddress(from: mapItem)
                if !address.isEmpty {
                    insertWithEviction(key: key, value: address)
                    return address
                }
            }
        } catch let error as MKError {
            handleGeocodeError(error, key: key)
        } catch {
            logger.debug("Geocoding failed for \(key): \(error.localizedDescription)")
        }
        
        return nil
    }
    
    /// Handle geocoding errors with exponential backoff for rate limiting
    private func handleGeocodeError(_ error: MKError, key: String) {
        switch error.code {
        case .serverFailure, .loadingThrottled:
            // Rate limited - apply exponential backoff
            rateLimitedUntil = Date().addingTimeInterval(currentBackoffSeconds)
            logger.warning("Geocoding rate limited - backing off \(self.currentBackoffSeconds)s")
            currentBackoffSeconds = min(currentBackoffSeconds * 2, maxBackoffSeconds)
            
        case .placemarkNotFound:
            // Cache negative result so we don't keep asking
            cacheNotFound(key: key)
            
        default:
            logger.debug("Geocoding failed for \(key): \(error.localizedDescription)")
        }
    }
    
    /// Cache a "not found" result to avoid repeated lookups
    private func cacheNotFound(key: String) {
        // Prune if at capacity
        if notFoundCache.count >= maxNotFoundEntries {
            // Remove ~20% of entries (arbitrary pruning)
            let toRemove = maxNotFoundEntries / 5
            for _ in 0..<toRemove {
                if let first = notFoundCache.first {
                    notFoundCache.remove(first)
                }
            }
        }
        notFoundCache.insert(key)
    }
    
    /// Insert with LRU eviction if at capacity
    private func insertWithEviction(key: String, value: String) {
        // Remove oldest if at capacity
        while insertionOrder.count >= maxEntries {
            if let oldestKey = insertionOrder.first {
                cache.removeValue(forKey: oldestKey)
                insertionOrder.removeFirst()
            }
        }
        
        cache[key] = value
        insertionOrder.append(key)
        
        // Persist to disk after each update
        saveToDisk()
    }
    
    /// Round coordinate to 4 decimal places for cache key.
    private nonisolated func cacheKey(for coordinate: CLLocationCoordinate2D) -> String {
        let lat = (coordinate.latitude * 10000).rounded() / 10000
        let lon = (coordinate.longitude * 10000).rounded() / 10000
        return "\(lat),\(lon)"
    }
    
    /// Format address from MKMapItem (iOS 26+ compatible)
    private func formatAddress(from mapItem: MKMapItem) -> String {
        // Use standard placemark properties for reliability
        let placemark = mapItem.placemark
        
        // precise address: "123 Main St"
        if let subThoroughfare = placemark.subThoroughfare, 
           let thoroughfare = placemark.thoroughfare {
            return "\(subThoroughfare) \(thoroughfare)"
        }
        
        // Street only: "Main St"
        if let thoroughfare = placemark.thoroughfare {
            return thoroughfare
        }
        
        // Fallback to name (often the POI name, e.g. "Apple Park")
        if let name = mapItem.name, !name.isEmpty {
            return name
        }
        
        // Final fallback to the system-formatted title
        return placemark.title ?? ""
        

    }
    
    /// Clear the cache (e.g., on memory warning).
    func clearCache() {
        cache.removeAll()
        insertionOrder.removeAll()
        saveToDisk()
    }
    
    // MARK: - Disk Persistence
    
    /// Serializable structure for disk storage
    private struct CacheData: Codable {
        let cache: [String: String]
        let insertionOrder: [String]
    }
    
    /// Save cache to disk
    private func saveToDisk() {
        let fileURL = cacheFileURL
        
        // Ensure directory exists
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create cache directory: \(error.localizedDescription)")
            return
        }
        
        // Save cache data
        let cacheData = CacheData(cache: cache, insertionOrder: insertionOrder)
        do {
            let data = try JSONEncoder().encode(cacheData)
            try data.write(to: fileURL, options: .atomic)
            logger.debug("Saved \(self.cache.count) cached addresses to disk")
        } catch {
            logger.error("Failed to save cache to disk: \(error.localizedDescription)")
        }
    }
}
