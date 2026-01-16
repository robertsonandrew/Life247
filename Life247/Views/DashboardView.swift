//
//  DashboardView.swift
//  Life247
//
//  Created by Andrew Robertson on 1/14/26.
//

import SwiftUI
import MapKit
import SwiftData

/// Main dashboard displaying the live map.
/// Uses MapCameraPolicy for camera behavior.
struct DashboardView: View {
    @Bindable var stateMachine: DriveStateMachine
    @ObservedObject var locationManager: LocationManager
    @Query(sort: \Drive.startTime, order: .reverse) private var allDrives: [Drive]
    @AppStorage("defaultZoomLevel") private var defaultZoomLevelRaw: String = MapZoomLevel.neighborhood.rawValue
    
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var trackingMode: MapTrackingMode = .follow
    @State private var mapHeading: Double = 0
    @State private var smoothedCourse: Double = 0
    @State private var showCompass: Bool = false
    @State private var lastCameraUpdate: Date = .distantPast
    @State private var historyTimeSpan: HistoryTimeSpan = .off
    @State private var routeCoordinates: [CLLocationCoordinate2D] = []  // Cached for stable polyline
    @State private var interpolator = LocationInterpolator()
    @State private var isHistoryPickerExpanded: Bool = false
    @Namespace private var mapScope
    
    private var zoomLevel: MapZoomLevel {
        MapZoomLevel(rawValue: defaultZoomLevelRaw) ?? .neighborhood
    }
    
    // Throttle camera updates (reduced for smoother tracking)
    private let cameraUpdateThrottle: TimeInterval = 0.05
    
    // Filtered drives for history overlay (derived from state)
    private var historyDrives: [Drive] {
        guard let windowStart = historyTimeSpan.windowStart else { return [] }
        let now = Date()
        
        return allDrives.filter { drive in
            // Exclude active drive
            guard drive.id != stateMachine.activeDrive?.id else { return false }
            // Intersection query: drive overlaps with time window
            guard let endTime = drive.endTime else { return false }
            return endTime >= windowStart && drive.startTime <= now
        }
    }
    
    var body: some View {
        ZStack {
            // Background map
            Map(position: $cameraPosition) {
                // History routes (behind active route)
                ForEach(historyDrives) { drive in
                    MapPolyline(coordinates: drive.pointsChronological.map { $0.coordinate })
                        .stroke(.gray.opacity(0.35), lineWidth: 2)
                }
                
                // Current location marker (uses interpolated position)
                if let displayCoord = interpolator.displayCoordinate {
                    Annotation("", coordinate: displayCoord) {
                        LocationMarkerWithHeading(
                            course: smoothedCourse,
                            mapHeading: mapHeading,
                            speed: interpolator.displaySpeed,
                            courseValid: interpolator.displayHeading >= 0
                        )
                    }
                }
                
                // Active drive route (uses cached coordinates for stability)
                if !routeCoordinates.isEmpty {
                    MapPolyline(coordinates: routeCoordinates)
                        .stroke(.blue, lineWidth: 4)
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            .mapControls {
                // Empty - we position compass manually
            }
            .mapScope(mapScope)
            .ignoresSafeArea()
            
            // Map controls overlay
            VStack {
                // Top row: Collapsible history time span picker
                Group {
                    if isHistoryPickerExpanded {
                        // Expanded: show all options
                        HStack(spacing: 4) {
                            ForEach(HistoryTimeSpan.allCases, id: \.self) { span in
                                Button {
                                    historyTimeSpan = span
                                    collapsePickerAfterDelay()
                                } label: {
                                    Text(span.label)
                                        .font(.caption)
                                        .fontWeight(historyTimeSpan == span ? .semibold : .regular)
                                        .foregroundColor(historyTimeSpan == span ? .white : .primary)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(
                                            historyTimeSpan == span
                                                ? Color.blue
                                                : Color.clear
                                        )
                                        .clipShape(Capsule())
                                }
                            }
                        }
                        .padding(6)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                    } else {
                        // Collapsed: show only current selection
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isHistoryPickerExpanded = true
                            }
                            collapsePickerAfterDelay()
                        } label: {
                            Text(historyTimeSpan.label)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(historyTimeSpan == .off ? .secondary : .blue)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: isHistoryPickerExpanded)
                .padding(.horizontal)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                
                Spacer()
                
                // Location button + Compass (bottom right, vertical stack)
                HStack {
                    Spacer()
                    
                    VStack(spacing: 12) {
                        Button(action: handleLocationButtonTap) {
                            Image(systemName: trackingModeIcon)
                                .font(.title2)
                                .foregroundColor(trackingModeColor)
                                .padding(12)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                        
                        // MapKit compass (only visible when non-north-up)
                        if showCompass {
                            MapCompass(scope: mapScope)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
        .onAppear {
            if let location = stateMachine.currentLocation {
                interpolator.receive(location)
                updateCamera(for: location)
            }
        }
        .onChange(of: stateMachine.currentLocation) { _, newLocation in
            guard let location = newLocation else { return }
            
            // Feed location to interpolator (always)
            interpolator.receive(location)
            
            // Skip camera updates if in free mode
            guard trackingMode != .free else { return }
            
            // Throttle camera updates
            let now = Date()
            guard now.timeIntervalSince(lastCameraUpdate) >= cameraUpdateThrottle else { return }
            
            updateCamera(for: location)
        }
        .onChange(of: stateMachine.activeDrive?.points.count) { _, newCount in
            // Update cached route only when points change
            guard let drive = stateMachine.activeDrive else {
                routeCoordinates = []
                return
            }
            routeCoordinates = drive.pointsChronological.map { $0.coordinate }
        }
        .onChange(of: stateMachine.state) { oldState, newState in
            // Auto-switch to drivingView when driving starts
            if oldState == .idle && (newState == .driving || newState == .maybeDriving) {
                if trackingMode != .free {
                    trackingMode = .drivingView
                    if let location = stateMachine.currentLocation {
                        updateCamera(for: location)
                    }
                }
            }
            
            // Return to follow when drive ends
            if newState == .idle && (oldState == .driving || oldState == .stopped) {
                if trackingMode == .drivingView {
                    trackingMode = .follow
                    if let location = stateMachine.currentLocation {
                        updateCamera(for: location)
                    }
                }
            }
        }
        .onMapCameraChange(frequency: .continuous) { context in
            // Capture map heading
            mapHeading = context.camera.heading
            
            // Show compass when map is rotated (>5° off north)
            showCompass = abs(mapHeading) > 5 && abs(mapHeading) < 355
        }
        .simultaneousGesture(
            // Detect any drag on the map to disable follow mode
            DragGesture(minimumDistance: 10)
                .onChanged { _ in
                    if trackingMode != .free {
                        trackingMode = .free
                    }
                }
        )
        .onChange(of: stateMachine.currentLocation?.course) { _, newCourse in
            guard let course = newCourse, course >= 0 else { return }
            let delta = abs(course - smoothedCourse)
            if delta > 5 || delta > 355 {
                withAnimation(.easeOut(duration: 0.3)) {
                    smoothedCourse = course
                }
            }
        }
    }
    
    // MARK: - Camera Updates
    
    private func updateCamera(for location: CLLocation) {
        let camera = mapCamera(
            for: trackingMode,
            location: location,
            speed: location.speed,
            zoomLevel: zoomLevel
        )
        
        // Use interactiveSpring for smooth, natural motion
        withAnimation(.interactiveSpring(response: 0.15, dampingFraction: 0.9)) {
            cameraPosition = .camera(camera)
        }
        
        lastCameraUpdate = Date()
    }
    
    private func collapsePickerAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation(.easeInOut(duration: 0.2)) {
                isHistoryPickerExpanded = false
            }
        }
    }
    
    // MARK: - Tracking Mode
    
    private var trackingModeIcon: String {
        switch trackingMode {
        case .free: return "location"
        case .follow, .followWithHeading, .drivingView: return "location.fill"
        }
    }
    
    private var trackingModeColor: Color {
        switch trackingMode {
        case .free: return .secondary
        case .follow, .followWithHeading: return .blue
        case .drivingView: return .green  // Distinct color for auto driving mode
        }
    }
    
    private func handleLocationButtonTap() {
        guard let location = stateMachine.currentLocation else { return }
        
        withAnimation {
            switch trackingMode {
            case .free:
                // From free → follow
                trackingMode = .follow
            case .follow:
                // From follow → heading
                trackingMode = .followWithHeading
            case .followWithHeading:
                // From heading → driving view (3D cinematic)
                trackingMode = .drivingView
            case .drivingView:
                // From driving view → back to free
                trackingMode = .free
            }
            
            updateCamera(for: location)
        }
    }
    
    private func resetToNorth() {
        guard let location = stateMachine.currentLocation else { return }
        
        withAnimation(.easeInOut(duration: 0.3)) {
            cameraPosition = .camera(MapCamera(
                centerCoordinate: location.coordinate,
                distance: 800,
                heading: 0,
                pitch: 0
            ))
        }
    }
}

// MARK: - Location Marker with Heading Cone

struct LocationMarkerWithHeading: View {
    let course: Double
    let mapHeading: Double
    let speed: Double
    let courseValid: Bool
    
    private var coneOpacity: Double {
        guard courseValid else { return 0 }
        if speed < 0.5 { return 0 }
        if speed < 2.0 { return (speed - 0.5) / 1.5 }
        return 1.0
    }
    
    private var effectiveRotation: Double {
        var angle = course - mapHeading
        while angle < 0 { angle += 360 }
        while angle >= 360 { angle -= 360 }
        return angle
    }
    
    var body: some View {
        ZStack {
            if coneOpacity > 0 {
                HeadingConeView()
                    .offset(x: 20, y: 0)
                    .rotationEffect(.degrees(effectiveRotation - 90))
                    .opacity(coneOpacity)
            }
            
            Circle()
                .fill(.blue.opacity(0.2))
                .frame(width: 60, height: 60)
            
            Circle()
                .fill(.blue)
                .frame(width: 20, height: 20)
            
            Circle()
                .stroke(.white, lineWidth: 3)
                .frame(width: 20, height: 20)
        }
    }
}

// MARK: - Heading Cone Shape

struct HeadingConeView: View {
    var body: some View {
        HeadingConeShape()
            .fill(
                LinearGradient(
                    colors: [.blue.opacity(0.6), .blue.opacity(0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: 40, height: 30)
    }
}

struct HeadingConeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let apex = CGPoint(x: rect.minX, y: rect.midY)
        let topRight = CGPoint(x: rect.maxX, y: rect.minY)
        let bottomRight = CGPoint(x: rect.maxX, y: rect.maxY)
        
        path.move(to: apex)
        path.addLine(to: topRight)
        path.addLine(to: bottomRight)
        path.closeSubpath()
        
        return path
    }
}

#Preview {
    DashboardView(
        stateMachine: DriveStateMachine(),
        locationManager: LocationManager()
    )
}
