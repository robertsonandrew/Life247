//
//  InteractiveGeofenceMap.swift
//  Life247
//
//  Created by Andrew Robertson on 1/23/26.
//

import SwiftUI
import MapKit

/// Interactive map for placing and resizing geofences.
/// - Tap to reposition the center point
/// - Slider to resize radius
/// - Shows live radius in meters
struct InteractiveGeofenceMap: View {
    @EnvironmentObject private var locationManager: LocationManager
    @Binding var coordinate: CLLocationCoordinate2D
    @Binding var radiusMeters: Double
    let icon: String
    
    /// Radius constraints (iOS geofencing limits)
    private let minRadius: Double = 20
    private let maxRadius: Double = 500
    
    /// Map camera position
    @State private var cameraPosition: MapCameraPosition
    
    /// Track if we need to recenter the camera
    @State private var needsRecenter = false
    
    init(coordinate: Binding<CLLocationCoordinate2D>, radiusMeters: Binding<Double>, icon: String) {
        self._coordinate = coordinate
        self._radiusMeters = radiusMeters
        self.icon = icon
        
        // Initialize camera centered on coordinate with appropriate zoom
        let minRadius = 20.0
        let maxRadius = 500.0
        let initialRadius = min(max(radiusMeters.wrappedValue, minRadius), maxRadius)
        let spanDegrees = (initialRadius * 4) / 111_320.0
        self._cameraPosition = State(initialValue: .region(MKCoordinateRegion(
            center: coordinate.wrappedValue,
            span: MKCoordinateSpan(latitudeDelta: max(spanDegrees, 0.002), longitudeDelta: max(spanDegrees, 0.002))
        )))
    }
    
    var body: some View {
        ZStack(alignment: .bottom) {
            // Map fills entire space
            mapContent
            
            // Floating radius slider positioned above bottom bar
            radiusSlider
                .padding(.bottom, 100)
        }
    }
    
    // MARK: - Map Content
    
    private var mapContent: some View {
        ZStack {
            MapReader { proxy in
                Map(position: $cameraPosition, interactionModes: [.pan, .zoom]) {
                    // Geofence circle (filled + bordered for modern appearance)
                    MapCircle(center: coordinate, radius: clampedRadiusMeters)
                        .foregroundStyle(.blue.opacity(0.12))
                    MapCircle(center: coordinate, radius: clampedRadiusMeters)
                        .foregroundStyle(.clear)
                        .stroke(.blue.opacity(0.55), lineWidth: 2)
                    
                    // Center marker
                    Annotation("", coordinate: coordinate) {
                        Image(systemName: icon)
                            .font(.title2)
                            .foregroundStyle(.blue)
                            .padding(8)
                            .background(
                                Circle()
                                    .fill(.white)
                                    .shadow(radius: 2)
                            )
                    }
                }
                .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .including([.store, .restaurant, .gasStation])))
                .onAppear {
                    if radiusMeters != clampedRadiusMeters {
                        radiusMeters = clampedRadiusMeters
                    }
                }
                .onTapGesture { location in
                    handleTap(at: location, proxy: proxy)
                }
            }
            
            // Radius badge overlay
            VStack {
                Spacer()
                HStack {
                    radiusLabel
                    Spacer()
                    hintLabel
                }
                .padding(8)
            }
        }
    }
    
    // MARK: - Radius Slider
    
    private var radiusSlider: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Slider(
                    value: $radiusMeters,
                    in: minRadius...maxRadius,
                    step: 10
                )
                .tint(.blue)
                .onChange(of: radiusMeters) { _, newValue in
                    updateCameraForRadius(newValue)
                }
                
                Image(systemName: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Text("Monitoring may trigger slightly outside this radius for reliability.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        .padding(.horizontal, 16)
    }
    
    // MARK: - Overlays
    
    private var radiusLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(Int(clampedRadiusMeters))m")
                .font(.subheadline)
                .fontWeight(.semibold)
                .monospacedDigit()
            if displayMonitoringRadiusMeters > clampedRadiusMeters + 0.5 {
                Text("Monitors at ~\(Int(displayMonitoringRadiusMeters))m")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }
    
    private var hintLabel: some View {
        Text("Tap to move")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
    }
    
    // MARK: - Actions
    
    private func handleTap(at location: CGPoint, proxy: MapProxy) {
        guard let tappedCoord = proxy.convert(location, from: .local) else { return }
        
        withAnimation(.spring(response: 0.4)) {
            coordinate = tappedCoord
            // Recenter camera on new position
            let spanDegrees = (clampedRadiusMeters * 4) / 111_320.0
            cameraPosition = .region(MKCoordinateRegion(
                center: tappedCoord,
                span: MKCoordinateSpan(latitudeDelta: max(spanDegrees, 0.002), longitudeDelta: max(spanDegrees, 0.002))
            ))
        }
    }
    
    private func updateCameraForRadius(_ radius: Double) {
        // Adjust zoom to keep the circle nicely framed
        let clampedRadius = min(max(radius, minRadius), maxRadius)
        let spanDegrees = (clampedRadius * 4) / 111_320.0
        withAnimation(.easeInOut(duration: 0.3)) {
            cameraPosition = .region(MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: max(spanDegrees, 0.002), longitudeDelta: max(spanDegrees, 0.002))
            ))
        }
    }

    private var clampedRadiusMeters: Double {
        min(max(radiusMeters, minRadius), maxRadius)
    }

    private var displayMonitoringRadiusMeters: Double {
        return LocationManager.recommendedMonitoringRadius(
            forUserRadiusMeters: clampedRadiusMeters,
            horizontalAccuracy: locationManager.currentHorizontalAccuracy
        )
    }


}

// MARK: - Preview

#Preview {
    struct PreviewWrapper: View {
        @State private var coordinate = CLLocationCoordinate2D(latitude: 36.0544, longitude: -95.8101)
        @State private var radius: Double = 100
        
        var body: some View {
            VStack {
                InteractiveGeofenceMap(
                    coordinate: $coordinate,
                    radiusMeters: $radius,
                    icon: "cart.fill"
                )
                .environmentObject(LocationManager())
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding()
                
                Text("Radius: \(Int(radius))m")
                Text("Lat: \(coordinate.latitude, specifier: "%.4f")")
                Text("Lon: \(coordinate.longitude, specifier: "%.4f")")
            }
        }
    }
    
    return PreviewWrapper()
}
