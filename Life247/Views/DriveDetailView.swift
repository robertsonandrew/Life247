//
//  DriveDetailView.swift
//  Life247
//
//  Created by Andrew Robertson on 1/14/26.
//

import SwiftUI
import SwiftData
import MapKit

/// Detailed view of a single drive with map visualization and statistics.
struct DriveDetailView: View {
    let drive: Drive
    @EnvironmentObject private var syncService: DriveSyncService
    @Query private var places: [Place]
    
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var isMapExpanded = false
    @State private var showAccelerationEvents = true
    
    /// Places relevant to this drive (within or near the route bounds)
    private var relevantPlaces: [Place] {
        guard let bounds = drive.routeBounds else { return [] }
        
        // Expand bounds slightly to catch places at start/end
        let expandedSpan = MKCoordinateSpan(
            latitudeDelta: bounds.span.latitudeDelta * 1.5,
            longitudeDelta: bounds.span.longitudeDelta * 1.5
        )
        let region = MKCoordinateRegion(center: bounds.center, span: expandedSpan)
        
        return places.filter { place in
            let lat = place.coordinate.latitude
            let lon = place.coordinate.longitude
            
            let minLat = region.center.latitude - region.span.latitudeDelta / 2
            let maxLat = region.center.latitude + region.span.latitudeDelta / 2
            let minLon = region.center.longitude - region.span.longitudeDelta / 2
            let maxLon = region.center.longitude + region.span.longitudeDelta / 2
            
            return lat >= minLat && lat <= maxLat && lon >= minLon && lon <= maxLon
        }
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Map
                mapSection
                
                // Stats
                statsSection
                
                // G-Force Events (if any)
                if !drive.accelerationEvents.isEmpty {
                    accelerationSection
                }
                
                // Details
                detailsSection
                
                // Cloud Sync (Surgical Fix)
                syncSection
            }
        }
        .bottomBarPadding()
        .navigationTitle("Drive Details")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            setupCamera()
        }
        .fullScreenCover(isPresented: $isMapExpanded) {
            ExpandedMapView(drive: drive, showAccelerationEvents: showAccelerationEvents)
        }
    }
    
    // MARK: - Map Section
    
    @AppStorage("showSpeedHeatMap") private var showSpeedHeatMap = false
    
    private var mapSection: some View {
        ZStack(alignment: .bottomTrailing) {
            Map(position: $cameraPosition) {
                // Route polyline (uses full resolution for detail view)
                if drive.points.count > 1 {
                    RoutePolyline(
                        points: drive.pointsChronological,
                        mode: showSpeedHeatMap ? .heatMap : .solid,
                        lineWidth: 7
                    )
                }
                
                // Acceleration event markers
                if showAccelerationEvents {
                    ForEach(drive.accelerationEvents, id: \.id) { event in
                        Annotation(event.eventType.displayName, coordinate: event.coordinate) {
                            AccelerationEventMarker(event: event, size: .regular)
                        }
                    }
                }
                
                // Saved places (only those relevant to this drive)
                ForEach(relevantPlaces) { place in
                    let ring = geofenceRingCoordinates(
                        center: place.coordinate,
                        radiusMeters: place.clampedRadiusMeters
                    )
                    MapPolyline(coordinates: ring)
                        .stroke(.orange.opacity(0.22), lineWidth: 4)
                    MapPolyline(coordinates: ring)
                        .stroke(.orange, lineWidth: 2)
                    
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
                        Image(systemName: "play.circle.fill")
                            .font(.title)
                            .foregroundStyle(.green)
                            .background(Circle().fill(.white).padding(2))
                    }
                }
                
                // End marker
                if let end = drive.endCoordinate {
                    Annotation("End", coordinate: end) {
                        Image(systemName: "flag.checkered.circle.fill")
                            .font(.title)
                            .foregroundStyle(.red)
                            .background(Circle().fill(.white).padding(2))
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            
            // Controls
            VStack(spacing: 8) {
                // Event toggle (only if events exist)
                if !drive.accelerationEvents.isEmpty {
                    Button {
                        showAccelerationEvents.toggle()
                    } label: {
                        Image(systemName: showAccelerationEvents ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                            .font(.headline)
                            .foregroundStyle(showAccelerationEvents ? .orange : .primary)
                            .padding(10)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                }
                
                // Expand button
                Button {
                    isMapExpanded = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .padding(10)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
            }
            .padding(12)
        }
        .frame(height: 300)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .contentShape(Rectangle())  // Makes entire area tappable
        .onTapGesture {
            isMapExpanded = true
        }
        .padding()
    }
    
    // MARK: - Stats Section
    
    private var statsSection: some View {
        HStack(spacing: 16) {
            StatCard(
                title: "Distance",
                value: drive.formattedDistance,
                icon: "road.lanes"
            )
            
            StatCard(
                title: "Duration",
                value: drive.formattedDuration,
                icon: "clock.fill"
            )
            
            StatCard(
                title: "Avg Speed",
                value: String(format: "%.0f mph", drive.averageSpeedMPH),
                icon: "gauge.medium"
            )
        }
        .padding(.horizontal)
    }
    
    // MARK: - Acceleration Events Section
    
    private var accelerationSection: some View {
        GroupBox {
            VStack(spacing: 16) {
                // Summary row
                HStack(spacing: 20) {
                    EventCountBadge(
                        count: drive.hardBrakeCount,
                        label: "Brakes",
                        color: .red,
                        icon: "arrow.down.circle.fill"
                    )
                    
                    EventCountBadge(
                        count: drive.hardAccelCount,
                        label: "Accels",
                        color: .orange,
                        icon: "arrow.up.circle.fill"
                    )
                    
                    EventCountBadge(
                        count: drive.hardCornerCount,
                        label: "Corners",
                        color: .yellow,
                        icon: "arrow.turn.up.right"
                    )
                    
                    if let maxG = drive.maxGForce {
                        EventCountBadge(
                            count: nil,
                            label: "Max G",
                            value: String(format: "%.2f", maxG),
                            color: .purple,
                            icon: "speedometer"
                        )
                    }
                }
                
                // Event list (collapsible)
                if drive.accelerationEvents.count <= 5 {
                    eventsList
                } else {
                    DisclosureGroup("All Events (\(drive.accelerationEvents.count))") {
                        eventsList
                    }
                }
            }
        } label: {
            Label("G-Force Events", systemImage: "exclamationmark.triangle")
        }
        .padding(.horizontal)
        .padding(.top)
    }
    
    private var eventsList: some View {
        VStack(spacing: 8) {
            ForEach(drive.accelerationEvents.sorted(by: { $0.timestamp < $1.timestamp }), id: \.id) { event in
                HStack {
                    AccelerationEventMarker(event: event, size: .small)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.eventType.displayName)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(event.timestamp.formatted(date: .omitted, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(event.formattedG)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                        Text("\(Int(event.speedMPH)) mph")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
    
    // MARK: - Details Section
    
    private var detailsSection: some View {
        VStack(spacing: 16) {
            // Time details
            GroupBox {
                VStack(spacing: 12) {
                    DetailRow(label: "Started", value: drive.startTime.formatted(date: .abbreviated, time: .shortened))
                    Divider()
                    DetailRow(label: "Ended", value: drive.endTime?.formatted(date: .abbreviated, time: .shortened) ?? "In Progress")
                    Divider()
                    DetailRow(label: "Outcome", value: endReasonLabel)
                }
            } label: {
                Label("Time", systemImage: "clock")
            }
            
            // Speed details
            GroupBox {
                VStack(spacing: 12) {
                    DetailRow(label: "Max Speed", value: String(format: "%.0f mph", drive.maxSpeedMPH))
                    Divider()
                    DetailRow(label: "Average Speed", value: String(format: "%.1f mph", drive.averageSpeedMPH))
                }
            } label: {
                Label("Speed", systemImage: "speedometer")
            }
            
            // Technical details
            GroupBox {
                VStack(spacing: 12) {
                    DetailRow(label: "GPS Points", value: "\(drive.points.count)")
                    Divider()
                    DetailRow(label: "Drive ID", value: drive.shortId)
                }
            } label: {
                Label("Technical", systemImage: "info.circle")
            }
        }
        .padding()
    }

    private var endReasonLabel: String {
        guard let endReason = drive.endReason else {
            return "In Progress"
        }
        switch endReason {
        case .visitArrival, .geofenceEntry, .geofenceEntryLowSpeed:
            return "Arrived"
        case .user:
            return "Manual End"
        case .walkingDetected:
            return "On Foot"
        case .inactivityTimeout:
            return "Auto End"
        case .safetyTimeout:
            return "Safety End"
        case .stuckRecovery:
            return "Recovered"
        case .appTermination, .systemSuspension, .lowBattery:
            return "System End"
        }
    }
    
    // MARK: - Sync Section
    
    private var syncSection: some View {
        GroupBox {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Status: \(drive.syncStatusDisplay)")
                        .fontWeight(.medium)
                        .foregroundStyle(statusColor)
                    
                    if let date = drive.syncedAt {
                        Text(date.formatted())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
                
                Button {
                    // Manual Re-Sync (Surgical Fix)
                    Task {
                        // Reset status to allow re-queue
                        drive.syncStatus = "pending"
                        syncService.queueDrive(drive)
                    }
                } label: {
                    Text("Sync Now")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.blue.opacity(0.1))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                }
                .disabled(drive.syncStatus == "pending")
            }
        } label: {
            Label("Cloud Sync", systemImage: "icloud")
        }
        .padding(.horizontal)
        .padding(.bottom, 20)
    }
    
    private var statusColor: Color {
        switch drive.syncStatus {
        case "synced": return .green
        case "failed": return .red
        case "pending": return .orange
        default: return .secondary
        }
    }
    
    // MARK: - Helpers
    
    private func setupCamera() {
        guard let bounds = drive.routeBounds else { return }
        cameraPosition = .region(MKCoordinateRegion(center: bounds.center, span: bounds.span))
    }
}

// MARK: - Expanded Map View

struct ExpandedMapView: View {
    let drive: Drive
    var showAccelerationEvents: Bool = true
    
    @Environment(\.dismiss) private var dismiss
    @Query private var places: [Place]
    
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var showEvents: Bool = true
    @AppStorage("showSpeedHeatMap") private var showSpeedHeatMap = false
    
    /// Places relevant to this drive (within or near the route bounds)
    private var relevantPlaces: [Place] {
        guard let bounds = drive.routeBounds else { return [] }
        
        let expandedSpan = MKCoordinateSpan(
            latitudeDelta: bounds.span.latitudeDelta * 1.5,
            longitudeDelta: bounds.span.longitudeDelta * 1.5
        )
        let region = MKCoordinateRegion(center: bounds.center, span: expandedSpan)
        
        return places.filter { place in
            let lat = place.coordinate.latitude
            let lon = place.coordinate.longitude
            
            let minLat = region.center.latitude - region.span.latitudeDelta / 2
            let maxLat = region.center.latitude + region.span.latitudeDelta / 2
            let minLon = region.center.longitude - region.span.longitudeDelta / 2
            let maxLon = region.center.longitude + region.span.longitudeDelta / 2
            
            return lat >= minLat && lat <= maxLat && lon >= minLon && lon <= maxLon
        }
    }
    
    var body: some View {
        ZStack {
            // Full screen map
            Map(position: $cameraPosition) {
                // Route polyline
                if drive.points.count > 1 {
                    RoutePolyline(
                        points: drive.pointsChronological,
                        mode: showSpeedHeatMap ? .heatMap : .solid,
                        lineWidth: 8
                    )
                }
                
                // Acceleration event markers
                if showEvents && showAccelerationEvents {
                    ForEach(drive.accelerationEvents, id: \.id) { event in
                        Annotation(event.eventType.displayName, coordinate: event.coordinate) {
                            AccelerationEventMarker(event: event, size: .large)
                        }
                    }
                }
                
                // Saved places (only those relevant to this drive)
                ForEach(relevantPlaces) { place in
                    let ring = geofenceRingCoordinates(
                        center: place.coordinate,
                        radiusMeters: place.clampedRadiusMeters
                    )
                    MapPolyline(coordinates: ring)
                        .stroke(.orange.opacity(0.22), lineWidth: 4)
                    MapPolyline(coordinates: ring)
                        .stroke(.orange, lineWidth: 2)
                    
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
                        Image(systemName: "play.circle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.green)
                            .background(Circle().fill(.white).padding(4))
                    }
                }
                
                // End marker
                if let end = drive.endCoordinate {
                    Annotation("End", coordinate: end) {
                        Image(systemName: "flag.checkered.circle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.red)
                            .background(Circle().fill(.white).padding(4))
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            .ignoresSafeArea()
            
            // Controls overlay
            VStack {
                // Top bar
                HStack {
                    // Close button
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .padding(12)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    
                    Spacer()
                    
                    // Drive info pill
                    HStack(spacing: 8) {
                        Text(drive.formattedDistance)
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text(drive.formattedDuration)
                        if !drive.accelerationEvents.isEmpty {
                            Text("•")
                                .foregroundStyle(.secondary)
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("\(drive.accelerationEvents.count)")
                        }
                    }
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    
                    Spacer()
                    
                    // Heat map toggle
                    Button {
                        showSpeedHeatMap.toggle()
                    } label: {
                        Image(systemName: showSpeedHeatMap ? "thermometer.high" : "thermometer.low")
                            .font(.headline)
                            .foregroundStyle(showSpeedHeatMap ? .orange : .primary)
                            .padding(12)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                
                Spacer()
                
                // Bottom controls
                HStack {
                    // Event toggle
                    if showAccelerationEvents && !drive.accelerationEvents.isEmpty {
                        Button {
                            showEvents.toggle()
                        } label: {
                            Image(systemName: showEvents ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                                .font(.headline)
                                .foregroundStyle(showEvents ? .orange : .primary)
                                .padding(12)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                    }
                    
                    Spacer()
                    
                    // Recenter button
                    Button {
                        recenterMap()
                    } label: {
                        Image(systemName: "location.fill")
                            .font(.headline)
                            .foregroundStyle(.blue)
                            .padding(12)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
        }
        .onAppear {
            showEvents = showAccelerationEvents
            setupCamera()
        }
    }
    
    private func setupCamera() {
        guard let bounds = drive.routeBounds else { return }
        cameraPosition = .region(MKCoordinateRegion(center: bounds.center, span: bounds.span))
    }
    
    private func recenterMap() {
        withAnimation(.easeInOut(duration: 0.3)) {
            setupCamera()
        }
    }
}

// MARK: - Stat Card

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.blue)
            
            Text(value)
                .font(.title3)
                .fontWeight(.bold)
                .monospacedDigit()
            
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Detail Row

struct DetailRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            
            Spacer()
            
            Text(value)
                .fontWeight(.medium)
        }
    }
}

// MARK: - Acceleration Event Marker

struct AccelerationEventMarker: View {
    let event: AccelerationEvent
    let size: MarkerSize
    
    enum MarkerSize {
        case small, regular, large
        
        var iconFont: Font {
            switch self {
            case .small: return .caption
            case .regular: return .body
            case .large: return .title2
            }
        }
        
        var padding: CGFloat {
            switch self {
            case .small: return 4
            case .regular: return 6
            case .large: return 8
            }
        }
    }
    
    private var color: Color {
        switch event.eventType {
        case .hardBrake: return .red
        case .hardAcceleration: return .orange
        case .hardCornerLeft, .hardCornerRight: return .yellow
        }
    }
    
    private var icon: String {
        switch event.eventType {
        case .hardBrake: return "arrow.down.circle.fill"
        case .hardAcceleration: return "arrow.up.circle.fill"
        case .hardCornerLeft: return "arrow.turn.up.left"
        case .hardCornerRight: return "arrow.turn.up.right"
        }
    }
    
    var body: some View {
        Image(systemName: icon)
            .font(size.iconFont)
            .foregroundStyle(color)
            .padding(size.padding)
            .background(Circle().fill(.white))
            .shadow(color: color.opacity(0.3), radius: 2, x: 0, y: 1)
    }
}

// MARK: - Event Count Badge

struct EventCountBadge: View {
    let count: Int?
    let label: String
    var value: String? = nil
    let color: Color
    let icon: String
    
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            
            Text(value ?? "\(count ?? 0)")
                .font(.title3)
                .fontWeight(.bold)
                .monospacedDigit()
            
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Geofence Ring Helper

fileprivate func geofenceRingCoordinates(
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

#Preview {
    NavigationStack {
        DriveDetailView(drive: Drive(
            startTime: Date().addingTimeInterval(-3600),
            endTime: Date(),
            distanceMeters: 8046.72
        ))
    }
}
