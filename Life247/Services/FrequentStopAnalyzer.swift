//
//  FrequentStopAnalyzer.swift
//  Life247
//
//  Created by Andrew Robertson on 1/15/26.
//

import Foundation
import CoreLocation

// MARK: - Frequent Stop Candidate

/// A cluster of repeated stops at the same location.
/// Computed in-memory, never persisted. Derived data only.
struct FrequentStopCandidate: Identifiable {
    let coordinate: CLLocationCoordinate2D
    let visitCount: Int
    let totalDuration: TimeInterval
    let lastVisited: Date
    
    /// Stable ID from rounded coordinates (deterministic across rebuilds)
    var id: String {
        let lat = (coordinate.latitude * 10000).rounded() / 10000
        let lon = (coordinate.longitude * 10000).rounded() / 10000
        return "\(lat)-\(lon)"
    }
    
    /// Formatted visit count label
    var visitLabel: String {
        "\(visitCount) visits"
    }
}

// MARK: - Analysis Result

/// Result of frequent stop analysis with fast lookup.
struct FrequentStopAnalysisResult {
    let candidates: [FrequentStopCandidate]
    let stopToCandidate: [UUID: FrequentStopCandidate]
    
    static let empty = FrequentStopAnalysisResult(candidates: [], stopToCandidate: [:])
}

// MARK: - Analyzer

/// Analyzes stops to find frequently-visited locations.
/// Caches results by stop IDs hash to avoid O(n²) re-analysis on every rebuild.
struct FrequentStopAnalyzer {
    
    // MARK: - Tuneable Constants
    
    /// Maximum distance to consider stops as same cluster (meters)
    static let clusterRadius: CLLocationDistance = 50
    
    /// Minimum visits to qualify as frequent
    static let minVisitCount: Int = 3
    
    /// Minimum stop duration to include (seconds)
    static let minStopDuration: TimeInterval = 300  // 5 minutes
    
    /// Maximum stops to analyze (performance guard)
    static let maxStopsToAnalyze: Int = 200
    
    // MARK: - Cache
    
    /// Cached result keyed by stop IDs hash
    private static var cachedResult: FrequentStopAnalysisResult?
    private static var cachedStopIdsHash: Int?
    private static var cachedPlaceIdsHash: Int?
    
    // MARK: - Analysis
    
    /// Analyze stops to find frequent stop candidates.
    /// Returns cached result if inputs unchanged.
    /// - Parameters:
    ///   - stops: All inferred stops (from TimelineBuilder)
    ///   - places: User-defined places (to exclude already-named locations)
    /// - Returns: Analysis result with candidates and stop-to-candidate mapping
    static func analyze(stops: [InferredStop], places: [Place]) -> FrequentStopAnalysisResult {
        // Compute input hashes for cache check
        let stopIdsHash = stops.map { $0.id }.hashValue
        let placeIdsHash = places.map { $0.id }.hashValue
        
        // Return cached result if inputs unchanged
        if let cached = cachedResult,
           stopIdsHash == cachedStopIdsHash,
           placeIdsHash == cachedPlaceIdsHash {
            return cached
        }
        
        // Cache miss - perform analysis
        let result = performAnalysis(stops: stops, places: places)
        
        // Update cache
        cachedResult = result
        cachedStopIdsHash = stopIdsHash
        cachedPlaceIdsHash = placeIdsHash
        
        return result
    }
    
    /// Clear the cache (e.g., on memory warning)
    static func clearCache() {
        cachedResult = nil
        cachedStopIdsHash = nil
        cachedPlaceIdsHash = nil
    }
    
    /// Perform the actual O(n²) analysis
    private static func performAnalysis(stops: [InferredStop], places: [Place]) -> FrequentStopAnalysisResult {
        // Filter stops: ignore short stops and those already matched to a Place
        let validStops = stops
            .filter { $0.duration >= minStopDuration }
            .filter { $0.matchedPlace == nil }
            .prefix(maxStopsToAnalyze)
        
        // Also exclude stops near any Place (even if not matched in timeline)
        let filteredStops = validStops.filter { stop in
            !places.contains { $0.contains(stop.location) }
        }
        
        // Cluster stops by proximity (first-stop centroid strategy)
        var clusters: [[InferredStop]] = []
        
        for stop in filteredStops {
            var addedToCluster = false
            
            for i in clusters.indices {
                if let centroid = clusters[i].first {
                    let distance = distanceBetween(stop.location, centroid.location)
                    if distance <= clusterRadius {
                        clusters[i].append(stop)
                        addedToCluster = true
                        break
                    }
                }
            }
            
            if !addedToCluster {
                clusters.append([stop])
            }
        }
        
        // Build candidates from clusters
        var candidates: [FrequentStopCandidate] = []
        var stopToCandidate: [UUID: FrequentStopCandidate] = [:]
        
        for cluster in clusters {
            // Count unique calendar days
            let uniqueDays = countUniqueDays(in: cluster)
            
            guard uniqueDays >= minVisitCount else { continue }
            guard let centroid = cluster.first else { continue }
            
            let candidate = FrequentStopCandidate(
                coordinate: centroid.location,
                visitCount: uniqueDays,
                totalDuration: cluster.reduce(0) { $0 + $1.duration },
                lastVisited: cluster.max(by: { $0.endTime < $1.endTime })?.endTime ?? Date()
            )
            
            candidates.append(candidate)
            
            // Map each stop in cluster to this candidate
            for stop in cluster {
                stopToCandidate[stop.id] = candidate
            }
        }
        
        // Sort by visit count descending
        candidates.sort { $0.visitCount > $1.visitCount }
        
        return FrequentStopAnalysisResult(
            candidates: candidates,
            stopToCandidate: stopToCandidate
        )
    }
    
    // MARK: - Helpers
    
    /// Count unique calendar days in a cluster of stops.
    private static func countUniqueDays(in stops: [InferredStop]) -> Int {
        let calendar = Calendar.current
        var uniqueDays: Set<Date> = []
        
        for stop in stops {
            let day = calendar.startOfDay(for: stop.startTime)
            uniqueDays.insert(day)
        }
        
        return uniqueDays.count
    }
    
    /// Distance between two coordinates in meters.
    private static func distanceBetween(
        _ a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        let locA = CLLocation(latitude: a.latitude, longitude: a.longitude)
        let locB = CLLocation(latitude: b.latitude, longitude: b.longitude)
        return locA.distance(from: locB)
    }
}
