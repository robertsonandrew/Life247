//
//  GeocodingCache.swift
//  Life247
//
//  Created by Andrew Robertson on 1/15/26.
//

import Foundation
import CoreLocation
import OSLog

/// Caches reverse geocoding results to avoid repeated lookups.
/// Keys are rounded coordinates (4 decimal places ≈ 11m precision).
/// Cache is persisted to disk to survive app restarts.
actor GeocodingCache {
    static let shared = GeocodingCache()
    
    private var cache: [String: String] = [:]
    private var insertionOrder: [String] = []  // Track key insertion order for LRU eviction
    private let maxEntries = 500
    private let geocoder = CLGeocoder()
    private let logger = Logger(subsystem: "com.life247", category: "GeocodingCache")
    
    /// File URL for persisted cache
    private var cacheFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let cacheDir = appSupport.appendingPathComponent("Life247", isDirectory: true)
        return cacheDir.appendingPathComponent("geocoding_cache.json")
    }
    
    private init() {
        loadFromDisk()
    }
    
    /// Get cached address or perform reverse geocoding.
    func address(for coordinate: CLLocationCoordinate2D) async -> String? {
        let key = cacheKey(for: coordinate)
        
        // Check cache first
        if let cached = cache[key] {
            return cached
        }
        
        // Reverse geocode
        let location = CLLocation(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            if let placemark = placemarks.first {
                let address = formatAddress(placemark)
                insertWithEviction(key: key, value: address)
                return address
            }
        } catch {
            logger.debug("Geocoding failed for \(key): \(error.localizedDescription)")
        }
        
        return nil
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
    private func cacheKey(for coordinate: CLLocationCoordinate2D) -> String {
        let lat = (coordinate.latitude * 10000).rounded() / 10000
        let lon = (coordinate.longitude * 10000).rounded() / 10000
        return "\(lat),\(lon)"
    }
    
    /// Format placemark into short address string.
    private func formatAddress(_ placemark: CLPlacemark) -> String {
        var components: [String] = []
        
        // Street address (e.g., "15060 S Grant St")
        if let subThoroughfare = placemark.subThoroughfare,
           let thoroughfare = placemark.thoroughfare {
            components.append("\(subThoroughfare) \(thoroughfare)")
        } else if let thoroughfare = placemark.thoroughfare {
            components.append(thoroughfare)
        }
        
        // If no street, try name or locality
        if components.isEmpty {
            if let name = placemark.name {
                components.append(name)
            } else if let locality = placemark.locality {
                components.append(locality)
            }
        }
        
        return components.joined(separator: ", ")
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
    
    /// Load cache from disk
    private func loadFromDisk() {
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
