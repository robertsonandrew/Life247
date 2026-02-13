//
//  RouteTraceShape.swift
//  Life247
//
//  Created by Andrew Robertson on 1/23/26.
//

import SwiftUI
import CoreLocation

/// A lightweight route silhouette that renders a drive's path as a normalized shape.
/// No map tiles needed — just the distinctive route geometry.
struct RouteTraceShape: Shape {
    let coordinates: [CLLocationCoordinate2D]
    
    /// Padding ratio to prevent the route from touching edges
    private let insetRatio: CGFloat = 0.1
    
    func path(in rect: CGRect) -> Path {
        guard coordinates.count >= 2 else {
            return Path()
        }
        
        // Find bounding box
        let lats = coordinates.map { $0.latitude }
        let lons = coordinates.map { $0.longitude }
        
        guard let minLat = lats.min(),
              let maxLat = lats.max(),
              let minLon = lons.min(),
              let maxLon = lons.max() else {
            return Path()
        }
        
        // Handle edge cases (single point or perfectly straight line)
        let latRange = max(maxLat - minLat, 0.0001)
        let lonRange = max(maxLon - minLon, 0.0001)
        
        // Calculate inset rect
        let inset = min(rect.width, rect.height) * insetRatio
        let drawRect = rect.insetBy(dx: inset, dy: inset)
        
        // Normalize coordinates to fit in draw rect while preserving aspect ratio
        let geoAspect = lonRange / latRange
        let rectAspect = drawRect.width / drawRect.height
        
        let (scaleX, scaleY, offsetX, offsetY): (CGFloat, CGFloat, CGFloat, CGFloat)
        
        if geoAspect > rectAspect {
            // Route is wider than tall - fit to width
            scaleX = drawRect.width / lonRange
            scaleY = scaleX
            offsetX = drawRect.minX
            offsetY = drawRect.midY - (latRange * scaleY / 2)
        } else {
            // Route is taller than wide - fit to height
            scaleY = drawRect.height / latRange
            scaleX = scaleY
            offsetX = drawRect.midX - (lonRange * scaleX / 2)
            offsetY = drawRect.minY
        }
        
        // Convert geo coordinates to points
        let points = coordinates.map { coord -> CGPoint in
            let x = (coord.longitude - minLon) * scaleX + offsetX
            // Flip Y axis (latitude increases upward, but SwiftUI Y increases downward)
            let y = (maxLat - coord.latitude) * scaleY + offsetY
            return CGPoint(x: x, y: y)
        }
        
        // Build path
        var path = Path()
        path.move(to: points[0])
        
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        
        return path
    }
}

/// A view wrapper that renders the route trace with proper styling
struct RouteTraceView: View {
    let coordinates: [CLLocationCoordinate2D]
    var color: Color = .red
    var lineWidth: CGFloat = 3.5
    
    var body: some View {
        RouteTraceShape(coordinates: coordinates)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
    }
}

/// A gradient route trace that shows direction of travel.
/// Color transitions smoothly along the path from start to end.
struct GradientRouteTraceView: View {
    let coordinates: [CLLocationCoordinate2D]
    var startColor: Color = .green  // Beginning of trip
    var endColor: Color = .red      // End of trip
    var lineWidth: CGFloat = 2.5
    
    /// Padding ratio to prevent the route from touching edges
    private let insetRatio: CGFloat = 0.1
    
    var body: some View {
        Canvas { context, size in
            guard coordinates.count >= 2 else { return }
            
            let points = normalizedPoints(in: size)
            guard points.count >= 2 else { return }
            
            let totalSegments = points.count - 1
            
            // Draw each segment with interpolated color
            for i in 0..<totalSegments {
                let t = Double(i) / Double(max(totalSegments - 1, 1))
                let segmentColor = interpolateColor(from: startColor, to: endColor, t: t)
                
                var segmentPath = Path()
                segmentPath.move(to: points[i])
                segmentPath.addLine(to: points[i + 1])
                
                context.stroke(
                    segmentPath,
                    with: .color(segmentColor),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                )
            }
            
            // Draw end point dot
            if let lastPoint = points.last {
                let dotSize: CGFloat = lineWidth * 2.5
                let dotRect = CGRect(
                    x: lastPoint.x - dotSize/2, 
                    y: lastPoint.y - dotSize/2, 
                    width: dotSize, 
                    height: dotSize
                )
                
                context.fill(Path(ellipseIn: dotRect), with: .color(endColor))
            }
        }
    }
    
    /// Convert geo coordinates to normalized points within the given size
    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        guard coordinates.count >= 2 else { return [] }
        
        let lats = coordinates.map { $0.latitude }
        let lons = coordinates.map { $0.longitude }
        
        guard let minLat = lats.min(),
              let maxLat = lats.max(),
              let minLon = lons.min(),
              let maxLon = lons.max() else {
            return []
        }
        
        // Handle edge cases
        let latRange = max(maxLat - minLat, 0.0001)
        let lonRange = max(maxLon - minLon, 0.0001)
        
        // Calculate inset rect
        let inset = min(size.width, size.height) * insetRatio
        let drawRect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        
        // Preserve aspect ratio
        let geoAspect = lonRange / latRange
        let rectAspect = drawRect.width / drawRect.height
        
        let (scaleX, scaleY, offsetX, offsetY): (CGFloat, CGFloat, CGFloat, CGFloat)
        
        if geoAspect > rectAspect {
            scaleX = drawRect.width / lonRange
            scaleY = scaleX
            offsetX = drawRect.minX
            offsetY = drawRect.midY - (latRange * scaleY / 2)
        } else {
            scaleY = drawRect.height / latRange
            scaleX = scaleY
            offsetX = drawRect.midX - (lonRange * scaleX / 2)
            offsetY = drawRect.minY
        }
        
        return coordinates.map { coord -> CGPoint in
            let x = (coord.longitude - minLon) * scaleX + offsetX
            let y = (maxLat - coord.latitude) * scaleY + offsetY
            return CGPoint(x: x, y: y)
        }
    }
    
    /// Interpolate between two colors
    private func interpolateColor(from: Color, to: Color, t: Double) -> Color {
        // Clamp t to [0, 1]
        let t = min(max(t, 0), 1)
        
        // Resolve colors to RGB components
        let fromComponents = UIColor(from).cgColor.components ?? [0, 0, 0, 1]
        let toComponents = UIColor(to).cgColor.components ?? [0, 0, 0, 1]
        
        // Handle grayscale colors (2 components) vs RGB (4 components)
        let fromR = fromComponents[0]
        let fromG = fromComponents.count > 2 ? fromComponents[1] : fromComponents[0]
        let fromB = fromComponents.count > 2 ? fromComponents[2] : fromComponents[0]
        let fromA = fromComponents.count > 2 ? fromComponents[3] : fromComponents[1]
        
        let toR = toComponents[0]
        let toG = toComponents.count > 2 ? toComponents[1] : toComponents[0]
        let toB = toComponents.count > 2 ? toComponents[2] : toComponents[0]
        let toA = toComponents.count > 2 ? toComponents[3] : toComponents[1]
        
        // Lerp each component
        let r = fromR + (toR - fromR) * t
        let g = fromG + (toG - fromG) * t
        let b = fromB + (toB - fromB) * t
        let a = fromA + (toA - fromA) * t
        
        return Color(red: r, green: g, blue: b, opacity: a)
    }
}

/// A route trace that colors segments based on speed.
struct SpeedRouteTraceView: View {
    let tracePoints: [(coordinate: CLLocationCoordinate2D, speedMPH: Double)]
    let speedColor: (Double) -> Color
    var lineWidth: CGFloat = 2.5
    
    /// Padding ratio
    private let insetRatio: CGFloat = 0.05
    
    var body: some View {
        Canvas { context, size in
            guard tracePoints.count >= 2 else { return }
            
            // Extract coordinates for normalization
            let coordinates = tracePoints.map { $0.coordinate }
            let points = normalizedPoints(for: coordinates, in: size)
            guard points.count >= 2 else { return }
            
            let totalSegments = points.count - 1
            
            // Draw each segment with interpolated color
            for i in 0..<totalSegments {
                let p1 = points[i]
                let p2 = points[i+1]
                
                let speed1 = tracePoints[i].speedMPH
                let speed2 = tracePoints[i+1].speedMPH
                let color1 = speedColor(speed1)
                let color2 = speedColor(speed2)
                
                // Create a linear gradient for this segment
                let shading = GraphicsContext.Shading.linearGradient(
                    Gradient(stops: [
                        .init(color: color1, location: 0),
                        .init(color: color2, location: 1)
                    ]),
                    startPoint: p1,
                    endPoint: p2
                )
                
                var segmentPath = Path()
                segmentPath.move(to: p1)
                segmentPath.addLine(to: p2)
                
                context.stroke(
                    segmentPath,
                    with: shading,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                )
            }
            
            // Draw start/end dots if needed (optional)
        }
    }
    
    /// Convert geo coordinates to normalized points within the given size
    private func normalizedPoints(for coordinates: [CLLocationCoordinate2D], in size: CGSize) -> [CGPoint] {
        guard coordinates.count >= 2 else { return [] }
        
        let lats = coordinates.map { $0.latitude }
        let lons = coordinates.map { $0.longitude }
        
        guard let minLat = lats.min(),
              let maxLat = lats.max(),
              let minLon = lons.min(),
              let maxLon = lons.max() else {
            return []
        }
        
        let latRange = max(maxLat - minLat, 0.0001)
        let lonRange = max(maxLon - minLon, 0.0001)
        
        let inset = min(size.width, size.height) * insetRatio
        let drawRect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        
        let geoAspect = lonRange / latRange
        let rectAspect = drawRect.width / drawRect.height
        
        let (scaleX, scaleY, offsetX, offsetY): (CGFloat, CGFloat, CGFloat, CGFloat)
        
        if geoAspect > rectAspect {
            // Route is wider than tall - fit to width
            scaleX = drawRect.width / lonRange
            scaleY = scaleX
            offsetX = drawRect.minX
            offsetY = drawRect.midY - (latRange * scaleY / 2)
        } else {
            // Route is taller than wide - fit to height, right-align horizontally
            scaleY = drawRect.height / latRange
            scaleX = scaleY
            offsetX = drawRect.maxX - (lonRange * scaleX)  // Right-align instead of center
            offsetY = drawRect.minY
        }
        
        return coordinates.map { coord -> CGPoint in
            let x = (coord.longitude - minLon) * scaleX + offsetX
            let y = (maxLat - coord.latitude) * scaleY + offsetY
            return CGPoint(x: x, y: y)
        }
    }
}

// MARK: - Convenience extension for Drive

extension Drive {
    /// Simplified coordinate array for route trace rendering
    var traceCoordinates: [CLLocationCoordinate2D] {
        // Use simplified points for performance (every Nth point)
        let points = pointsChronological
        guard points.count > 2 else {
            return points.map { $0.coordinate }
        }
        
        // For traces, we want ~20-30 points max for smooth curves without excess detail
        let step = max(1, points.count / 25)
        var result: [CLLocationCoordinate2D] = []
        
        for i in stride(from: 0, to: points.count, by: step) {
            result.append(points[i].coordinate)
        }
        
        // Always include the last point
        if let last = points.last, result.last?.latitude != last.latitude || result.last?.longitude != last.longitude {
            result.append(last.coordinate)
        }
        
        return result
    }

    /// Simplified coordinate + speed array for route trace rendering.
    /// Returns cached data if available; otherwise computes, caches (lazy backfill), and returns.
    var tracePointsWithSpeed: [(coordinate: CLLocationCoordinate2D, speedMPH: Double)] {
        // 1. Check persisted cache
        if let data = cachedTraceData,
           let decoded = try? JSONDecoder().decode([CachedTracePoint].self, from: data) {
            return decoded.map {
                (CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon), $0.speed)
            }
        }
        // 2. Cache miss — compute and lazy-backfill
        let result = computeTracePointsWithSpeed()
        let encoded = result.map {
            CachedTracePoint(lat: $0.coordinate.latitude,
                             lon: $0.coordinate.longitude,
                             speed: $0.speedMPH)
        }
        cachedTraceData = try? JSONEncoder().encode(encoded)
        return result
    }

    /// Compute sampled trace from full point set (expensive — sorts all points).
    func computeTracePointsWithSpeed() -> [(coordinate: CLLocationCoordinate2D, speedMPH: Double)] {
        // Use simplified points for performance (every Nth point)
        let points = pointsChronological
        guard points.count > 2 else {
            return points.map { ($0.coordinate, $0.speedMPH) }
        }
        
        // For traces, we want ~30 points for sufficient speed granularity
        let step = max(1, points.count / 30)
        var result: [(coordinate: CLLocationCoordinate2D, speedMPH: Double)] = []
        
        for i in stride(from: 0, to: points.count, by: step) {
            result.append((points[i].coordinate, points[i].speedMPH))
        }
        
        // Always include the last point
        if let last = points.last {
            let lastCoord = last.coordinate
            if let prev = result.last, (prev.coordinate.latitude != lastCoord.latitude || prev.coordinate.longitude != lastCoord.longitude) {
                result.append((last.coordinate, last.speedMPH))
            } else if result.isEmpty {
                result.append((last.coordinate, last.speedMPH))
            }
        }
        
        return result
    }
}

// MARK: - Preview

#Preview("Route Traces") {
    VStack(spacing: 20) {
        // Simulated L-shaped route
        RouteTraceView(
            coordinates: [
                CLLocationCoordinate2D(latitude: 36.0, longitude: -95.9),
                CLLocationCoordinate2D(latitude: 36.0, longitude: -95.85),
                CLLocationCoordinate2D(latitude: 36.0, longitude: -95.8),
                CLLocationCoordinate2D(latitude: 36.02, longitude: -95.8),
                CLLocationCoordinate2D(latitude: 36.04, longitude: -95.8),
            ]
        )
        .frame(width: 44, height: 44)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        
        // Simulated curved route
        RouteTraceView(
            coordinates: [
                CLLocationCoordinate2D(latitude: 36.0, longitude: -95.9),
                CLLocationCoordinate2D(latitude: 36.01, longitude: -95.88),
                CLLocationCoordinate2D(latitude: 36.02, longitude: -95.85),
                CLLocationCoordinate2D(latitude: 36.025, longitude: -95.82),
                CLLocationCoordinate2D(latitude: 36.03, longitude: -95.8),
            ],
            color: .orange
        )
        .frame(width: 44, height: 44)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        
        // Straight line
        RouteTraceView(
            coordinates: [
                CLLocationCoordinate2D(latitude: 36.0, longitude: -95.9),
                CLLocationCoordinate2D(latitude: 36.0, longitude: -95.8),
            ],
            color: .green
        )
        .frame(width: 44, height: 44)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    .padding()
}

#Preview("Gradient Route Traces") {
    VStack(spacing: 20) {
        // L-shaped route with gradient
        GradientRouteTraceView(
            coordinates: [
                CLLocationCoordinate2D(latitude: 36.0, longitude: -95.9),
                CLLocationCoordinate2D(latitude: 36.0, longitude: -95.85),
                CLLocationCoordinate2D(latitude: 36.0, longitude: -95.8),
                CLLocationCoordinate2D(latitude: 36.02, longitude: -95.8),
                CLLocationCoordinate2D(latitude: 36.04, longitude: -95.8),
            ]
        )
        .frame(width: 44, height: 44)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        
        // Curved route with gradient
        GradientRouteTraceView(
            coordinates: [
                CLLocationCoordinate2D(latitude: 36.0, longitude: -95.9),
                CLLocationCoordinate2D(latitude: 36.01, longitude: -95.88),
                CLLocationCoordinate2D(latitude: 36.02, longitude: -95.85),
                CLLocationCoordinate2D(latitude: 36.025, longitude: -95.82),
                CLLocationCoordinate2D(latitude: 36.03, longitude: -95.8),
            ]
        )
        .frame(width: 44, height: 44)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        
        // Custom colors (blue → orange)
        GradientRouteTraceView(
            coordinates: [
                CLLocationCoordinate2D(latitude: 36.0, longitude: -95.9),
                CLLocationCoordinate2D(latitude: 36.01, longitude: -95.87),
                CLLocationCoordinate2D(latitude: 36.02, longitude: -95.84),
                CLLocationCoordinate2D(latitude: 36.03, longitude: -95.81),
            ],
            startColor: .blue,
            endColor: .orange
        )
        .frame(width: 44, height: 44)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        
        // Larger size to see gradient detail
        GradientRouteTraceView(
            coordinates: [
                CLLocationCoordinate2D(latitude: 36.0, longitude: -95.9),
                CLLocationCoordinate2D(latitude: 36.005, longitude: -95.88),
                CLLocationCoordinate2D(latitude: 36.01, longitude: -95.86),
                CLLocationCoordinate2D(latitude: 36.02, longitude: -95.85),
                CLLocationCoordinate2D(latitude: 36.03, longitude: -95.83),
                CLLocationCoordinate2D(latitude: 36.035, longitude: -95.8),
            ],
            lineWidth: 3
        )
        .frame(width: 100, height: 100)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    .padding()
}
