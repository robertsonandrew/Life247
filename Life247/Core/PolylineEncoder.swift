//
//  PolylineEncoder.swift
//  Life247
//
//  Created by Andrew Robertson on 1/17/26.
//

import Foundation
import CoreLocation

/// Polyline compression utilities for efficient drive data upload
/// Uses Douglas-Peucker simplification + Google polyline encoding
struct PolylineEncoder {
    
    // MARK: - Public API
    
    /// Simplify and encode coordinates into a compact polyline string
    /// - Parameters:
    ///   - coordinates: Raw coordinate array
    ///   - epsilon: Tolerance for simplification (degrees, ~0.00005 = 5m)
    /// - Returns: Google-encoded polyline string
    static func encode(_ coordinates: [CLLocationCoordinate2D], epsilon: Double = 0.00005) -> String {
        let simplified = simplify(coordinates, epsilon: epsilon)
        return googleEncode(simplified)
    }
    
    /// Douglas-Peucker line simplification algorithm
    /// Reduces point count while preserving route shape
    /// - Parameters:
    ///   - coordinates: Original coordinate array
    ///   - epsilon: Tolerance in degrees (~0.00005 ≈ 5m)
    /// - Returns: Simplified coordinate array (typically 80-95% reduction)
    static func simplify(_ coordinates: [CLLocationCoordinate2D], epsilon: Double = 0.00005) -> [CLLocationCoordinate2D] {
        guard coordinates.count > 2 else { return coordinates }
        
        let start = coordinates.first!
        let end = coordinates.last!
        
        // Find the point with maximum distance from the line
        var maxDist: Double = 0
        var index = 0
        
        for i in 1..<coordinates.count - 1 {
            let dist = perpendicularDistance(
                point: coordinates[i],
                lineStart: start,
                lineEnd: end
            )
            if dist > maxDist {
                maxDist = dist
                index = i
            }
        }
        
        // If max distance exceeds epsilon, recursively simplify
        if maxDist > epsilon {
            let left = simplify(Array(coordinates[0...index]), epsilon: epsilon)
            let right = simplify(Array(coordinates[index..<coordinates.count]), epsilon: epsilon)
            // Combine results, avoiding duplicate point at index
            return Array(left.dropLast()) + right
        } else {
            // All points within tolerance - keep only endpoints
            return [start, end]
        }
    }
    
    /// Overload for LocationPoint to preserve metadata (e.g. speed)
    static func simplifyPoints(_ points: [LocationPoint], epsilon: Double = 0.00005) -> [LocationPoint] {
        guard points.count > 2 else { return points }
        
        let start = points.first!
        let end = points.last!
        
        var maxDist: Double = 0
        var index = 0
        
        // Find point with max distance
        for i in 1..<points.count - 1 {
            let dist = perpendicularDistance(
                point: points[i].coordinate,
                lineStart: start.coordinate,
                lineEnd: end.coordinate
            )
            if dist > maxDist {
                maxDist = dist
                index = i
            }
        }
        
        if maxDist > epsilon {
            let left = simplifyPoints(Array(points[0...index]), epsilon: epsilon)
            let right = simplifyPoints(Array(points[index..<points.count]), epsilon: epsilon)
            return Array(left.dropLast()) + right
        } else {
            return [start, end]
        }
    }
    
    // MARK: - Google Polyline Encoding
    
    /// Encode coordinates using Google's polyline algorithm
    /// Reference: https://developers.google.com/maps/documentation/utilities/polylinealgorithm
    static func googleEncode(_ coordinates: [CLLocationCoordinate2D]) -> String {
        var lastLat: Int = 0
        var lastLon: Int = 0
        var result = ""
        
        for point in coordinates {
            let lat = Int(round(point.latitude * 1e5))
            let lon = Int(round(point.longitude * 1e5))
            
            let dLat = lat - lastLat
            let dLon = lon - lastLon
            
            result += encodeSignedNumber(dLat)
            result += encodeSignedNumber(dLon)
            
            lastLat = lat
            lastLon = lon
        }
        
        return result
    }
    
    /// Decode a Google polyline string back to coordinates
    /// Useful for testing and visualization
    static func decode(_ polyline: String) -> [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        var index = polyline.startIndex
        var lat = 0
        var lon = 0
        
        while index < polyline.endIndex {
            // Decode latitude
            var result = 0
            var shift = 0
            var byte: Int
            
            repeat {
                byte = Int(polyline[index].asciiValue!) - 63
                result |= (byte & 0x1f) << shift
                shift += 5
                index = polyline.index(after: index)
            } while byte >= 0x20 && index < polyline.endIndex
            
            let deltaLat = ((result & 1) != 0) ? ~(result >> 1) : (result >> 1)
            lat += deltaLat
            
            // Decode longitude
            result = 0
            shift = 0
            
            repeat {
                guard index < polyline.endIndex else { break }
                byte = Int(polyline[index].asciiValue!) - 63
                result |= (byte & 0x1f) << shift
                shift += 5
                index = polyline.index(after: index)
            } while byte >= 0x20 && index < polyline.endIndex
            
            let deltaLon = ((result & 1) != 0) ? ~(result >> 1) : (result >> 1)
            lon += deltaLon
            
            coordinates.append(CLLocationCoordinate2D(
                latitude: Double(lat) / 1e5,
                longitude: Double(lon) / 1e5
            ))
        }
        
        return coordinates
    }
    
    // MARK: - Private Helpers
    
    private static func perpendicularDistance(
        point: CLLocationCoordinate2D,
        lineStart: CLLocationCoordinate2D,
        lineEnd: CLLocationCoordinate2D
    ) -> Double {
        let dx = lineEnd.longitude - lineStart.longitude
        let dy = lineEnd.latitude - lineStart.latitude
        
        // Handle degenerate case where line is a point
        if dx == 0 && dy == 0 {
            return hypot(
                point.longitude - lineStart.longitude,
                point.latitude - lineStart.latitude
            )
        }
        
        // Calculate parameter t for projection onto line
        let t = ((point.longitude - lineStart.longitude) * dx +
                 (point.latitude - lineStart.latitude) * dy) / (dx * dx + dy * dy)
        
        // Calculate projection point
        let projX = lineStart.longitude + t * dx
        let projY = lineStart.latitude + t * dy
        
        // Return distance from point to projection
        return hypot(point.longitude - projX, point.latitude - projY)
    }
    
    private static func encodeSignedNumber(_ num: Int) -> String {
        var sNum = num << 1
        if num < 0 {
            sNum = ~sNum
        }
        return encodeNumber(sNum)
    }
    
    private static func encodeNumber(_ num: Int) -> String {
        var num = num
        var result = ""
        
        while num >= 0x20 {
            let nextValue = (0x20 | (num & 0x1f)) + 63
            result.append(Character(UnicodeScalar(nextValue)!))
            num >>= 5
        }
        
        result.append(Character(UnicodeScalar(num + 63)!))
        return result
    }
}
