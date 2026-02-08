//
//  FullScreenMapView.swift
//  Life247
//
//  Created by Andrew Robertson on 1/23/26.
//

import SwiftUI
import SwiftData
import MapKit

/// Full-screen interactive map view for viewing a drive route.
/// Presented as a sheet/fullScreenCover from history row map thumbnails.
struct FullScreenMapView: View {
    let drive: Drive
    @Environment(\.dismiss) private var dismiss
    @Query private var places: [Place]
    
    @State private var mapCameraPosition: MapCameraPosition = .automatic
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            mapContent
            
            dismissButton
        }
        .ignoresSafeArea(edges: .all)
        .onAppear {
            setupCamera()
        }
    }
    
    // MARK: - Map Content
    
    private var mapContent: some View {
        Map(position: $mapCameraPosition) {
            // Route polyline
            if drive.points.count > 1 {
                MapPolyline(coordinates: drive.pointsChronological.map { $0.coordinate })
                    .stroke(.blue, lineWidth: 4)
            }
            
            // Saved places with geofence circles
            ForEach(places) { place in
                // Geofence ring (stroke-only to avoid fill artifacts)
                let ring = geofenceRingCoordinates(
                    center: place.coordinate,
                    radiusMeters: place.clampedRadiusMeters
                )
                MapPolyline(coordinates: ring)
                    .stroke(.orange.opacity(0.22), lineWidth: 4)
                MapPolyline(coordinates: ring)
                    .stroke(.orange, lineWidth: 2)
                
                // Place marker
                Annotation(place.name, coordinate: place.coordinate) {
                    Image(systemName: place.icon)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(Circle().fill(.orange))
                        .shadow(radius: 2)
                }
            }
            
            // Start marker
            if let start = drive.startCoordinate {
                Annotation("Start", coordinate: start) {
                    ZStack {
                        Circle()
                            .fill(.green)
                            .frame(width: 24, height: 24)
                        Circle()
                            .fill(.white)
                            .frame(width: 10, height: 10)
                    }
                }
            }
            
            // End marker
            if let end = drive.endCoordinate {
                Annotation("End", coordinate: end) {
                    ZStack {
                        Circle()
                            .fill(.red)
                            .frame(width: 24, height: 24)
                        Circle()
                            .fill(.white)
                            .frame(width: 10, height: 10)
                    }
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .mapControls {
            MapCompass()
            MapScaleView()
            MapUserLocationButton()
        }
    }
    
    // MARK: - Dismiss Button
    
    private var dismissButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.title)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .padding(.top, 44) // Account for status bar
    }
    
    // MARK: - Camera Setup
    
    private func setupCamera() {
        guard let bounds = drive.routeBounds else { return }
        
        // Add some padding to the bounds
        let paddedSpan = MKCoordinateSpan(
            latitudeDelta: bounds.span.latitudeDelta * 1.2,
            longitudeDelta: bounds.span.longitudeDelta * 1.2
        )
        
        let region = MKCoordinateRegion(center: bounds.center, span: paddedSpan)
        mapCameraPosition = .region(region)
    }

    private func geofenceRingCoordinates(
        center: CLLocationCoordinate2D,
        radiusMeters: CLLocationDistance,
        segments: Int = 96
    ) -> [CLLocationCoordinate2D] {
        let clampedSegments = max(24, min(192, segments))
        let centerPoint = MKMapPoint(center)
        let pointsPerMeter = MKMapPointsPerMeterAtLatitude(center.latitude)
        let mapRadius = radiusMeters * pointsPerMeter

        var coordinates: [CLLocationCoordinate2D] = []
        coordinates.reserveCapacity(clampedSegments + 1)

        for index in 0...clampedSegments {
            let theta = (Double(index) / Double(clampedSegments)) * 2.0 * .pi
            let x = centerPoint.x + (mapRadius * cos(theta))
            let y = centerPoint.y + (mapRadius * sin(theta))
            coordinates.append(MKMapPoint(x: x, y: y).coordinate)
        }

        return coordinates
    }
}

// MARK: - Drive Info Overlay (Optional Enhancement)

private struct DriveInfoOverlay: View {
    let drive: Drive
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(drive.dynamicTitle)
                .font(.headline)
            
            HStack(spacing: 12) {
                Label(drive.formattedDistance, systemImage: "road.lanes")
                Label(drive.formattedDuration, systemImage: "clock")
                Label(String(format: "%.0f mph", drive.maxSpeedMPH), systemImage: "speedometer")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    FullScreenMapView(drive: Drive())
}
