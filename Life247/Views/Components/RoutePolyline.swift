//
//  RoutePolyline.swift
//  Life247
//
//  Created by Andrew Robertson on 1/15/26.
//

import SwiftUI
import MapKit

/// Render mode for route polylines
enum RouteRenderMode {
    case solid          // Single color line
    case heatMap        // Speed-based color segments
}

/// Reusable route polyline that supports solid or heat map rendering.
/// Heat map uses segmented polylines with speed-based colors (not gradients).
struct RoutePolyline: MapContent {
    let points: [LocationPoint]
    let mode: RouteRenderMode
    let lineWidth: CGFloat
    
    init(points: [LocationPoint], mode: RouteRenderMode = .solid, lineWidth: CGFloat = 4) {
        self.points = points
        self.mode = mode
        self.lineWidth = lineWidth
    }
    
    var body: some MapContent {
        switch mode {
        case .solid:
            solidPolyline
        case .heatMap:
            heatMapPolylines
        }
    }
    
    // MARK: - Solid Mode
    
    @MapContentBuilder
    private var solidPolyline: some MapContent {
        if points.count > 1 {
            MapPolyline(coordinates: points.map { $0.coordinate })
                .stroke(.blue, lineWidth: lineWidth)
        }
    }
    
    // MARK: - Heat Map Mode (Segmented)
    
    @MapContentBuilder
    private var heatMapPolylines: some MapContent {
        ForEach(segments, id: \.id) { segment in
            MapPolyline(coordinates: segment.coordinates)
                .stroke(segment.color, lineWidth: lineWidth)
        }
    }
    
    /// Break route into colored segments based on speed
    private var segments: [RouteSegment] {
        guard points.count > 1 else { return [] }
        
        var result: [RouteSegment] = []
        let segmentSize = 3 // Group every N points into a segment
        
        for i in stride(from: 0, to: points.count - 1, by: segmentSize) {
            let endIndex = min(i + segmentSize, points.count - 1)
            let segmentPoints = Array(points[i...endIndex])
            
            // Calculate average speed for this segment
            let avgSpeed = segmentPoints.reduce(0.0) { $0 + $1.speedMPH } / Double(segmentPoints.count)
            
            result.append(RouteSegment(
                id: i,
                coordinates: segmentPoints.map { $0.coordinate },
                color: speedColor(for: avgSpeed)
            ))
        }
        
        return result
    }
    
    /// Map speed (mph) to color
    /// 0-5: Red (stopped/traffic)
    /// 5-25: Orange (slow)
    /// 25-45: Yellow (city)
    /// 45-65: Green (highway)
    /// 65+: Blue/Purple (fast)
    private func speedColor(for speed: Double) -> Color {
        switch speed {
        case ..<5:
            return .red
        case 5..<25:
            return .orange
        case 25..<45:
            return .yellow
        case 45..<65:
            return .green
        default:
            return Color(red: 0.4, green: 0.6, blue: 1.0) // Light blue
        }
    }
}

/// A segment of the route with a single color
private struct RouteSegment: Identifiable {
    let id: Int
    let coordinates: [CLLocationCoordinate2D]
    let color: Color
}

#Preview {
    Map {
        // Preview would need sample data
    }
}
