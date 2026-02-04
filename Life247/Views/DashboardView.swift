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
    @Query private var savedPlaces: [Place]
    @AppStorage("defaultZoomLevel") private var defaultZoomLevelRaw: String = MapZoomLevel.area.rawValue
    @AppStorage("showPlacesOnMap") private var showPlacesOnMap = true
    @Environment(\.bottomBarHeight) private var bottomBarHeight
    
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var trackingMode: MapTrackingMode = .follow
    @State private var mapHeading: Double = 0
    @State private var cameraDistance: Double = 800  // meters from ground
    @State private var showCompass: Bool = false
    @State private var lastCameraUpdate: Date = .distantPast
    @State private var lastCourseHeading: Double = 0
    @State private var hasCourseHeading: Bool = false
    @AppStorage("historyTimeSpan") private var historyTimeSpanRaw: String = HistoryTimeSpan.off.rawValue
    @State private var routeCoordinates: [CLLocationCoordinate2D] = []  // Cached for stable polyline
    // REMOVED: @State private var interpolator = LocationInterpolator() - using Apple's native puck and GPS directly
    @Namespace private var mapScope

    @State private var selectedPlaceForDwell: Place?

    @State private var softDwell: SoftDwell?
    @State private var softDwellCandidate: SoftDwellCandidate?
    
    // Cache for history routes to prevent re-sorting on every frame
    @State private var historyRouteCache: [UUID: HistoryRoute] = [:]
    
    private var historyTimeSpan: HistoryTimeSpan {
        HistoryTimeSpan(rawValue: historyTimeSpanRaw) ?? .off
    }
    
    private var zoomLevel: MapZoomLevel {
        MapZoomLevel(rawValue: defaultZoomLevelRaw) ?? .area
    }

    private let minSpeedForHeadingMPH: Double = 3.0
    private let headingSmoothingAlpha: Double = 0.25
    
    /// Only show saved places when setting is enabled AND camera is at reasonable zoom level
    private var shouldShowPlaces: Bool {
        showPlacesOnMap && cameraDistance < 50000  // ~30 miles - hides when zoomed way out
    }
    
    // Camera updates now driven directly by stateMachine.currentLocation
    // Apple's native UserAnnotation handles puck interpolation internally
    
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
    
    /// The place where active dwell is happening (matches by name)
    private var activeDwellPlace: Place? {
        if let dwell = stateMachine.activeDwellSummary {
            return savedPlaces.first { $0.name == dwell.placeName }
        } else if let soft = softDwell {
            return savedPlaces.first { $0.name == soft.placeName }
        }
        return nil
    }
    
    var body: some View {
        ZStack {
            mapView
            controlsOverlay
        }
        .sheet(item: $selectedPlaceForDwell) { place in
            NavigationStack {
                PlaceDwellView(place: place)
            }
        }
        .onAppear {
            if let location = stateMachine.currentLocation {
                let age = Date().timeIntervalSince(location.timestamp)
                // Only use fresh locations for initial camera (avoid stale home cache)
                if age <= 12.0 {
                    updateCamera(for: location)
                }
            }
            
            // Force drivingView if we recovered into an active driving state
            if stateMachine.state == .driving || stateMachine.state == .maybeDriving {
                trackingMode = .drivingView
            }
        }
        // Use .task for route initialization - runs before first render, guaranteed
        .task {
            if let drive = stateMachine.activeDrive {
                routeCoordinates = drive.pointsChronological.map { $0.coordinate }
            }
        }
        .onChange(of: stateMachine.currentLocation) { _, newLocation in
            guard let location = newLocation else { return }
            
            // Update camera directly from GPS location (no interpolator needed)
            if trackingMode != .free {
                let heading = resolvedHeading(for: location)
                updateCameraFromLocation(location: location, heading: heading)
            }

            updateSoftDwellIfNeeded(currentLocation: location)
        }
        // Heading updates only needed for compass display, not for camera
        .onChange(of: locationManager.currentHeading) { _, _ in
            // Heading is used by Apple's native puck internally
            // We only track it for compass display (via mapHeading from onMapCameraChange)
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
            if newState == .driving || newState == .maybeDriving {
                // Auto-rotate map when driving (if user hasn't panned away)
                if trackingMode == .follow {
                    trackingMode = .followWithHeading
                    if let location = stateMachine.currentLocation {
                        updateCamera(for: location)
                    }
                }
            } else if newState == .idle {
                // Return to north-up when drive ends (unless user is free)
                if trackingMode == .followWithHeading || trackingMode == .drivingView {
                    trackingMode = .follow
                    if let location = stateMachine.currentLocation {
                        updateCamera(for: location)
                    }
                }
            }
        }
        .onChange(of: defaultZoomLevelRaw) { _, _ in
            // Zoom setting changed (e.g., from Settings) — update camera immediately
            if trackingMode != .free, let location = stateMachine.currentLocation {
                updateCamera(for: location)
            }
        }
        // Update history cache when history span changes or drives change
        .onChange(of: historyTimeSpan) { _, _ in
            updateHistoryCache()
        }
        .onChange(of: allDrives.count) { _, _ in
            updateHistoryCache()
        }
        .task {
            updateHistoryCache()
        }
        .onMapCameraChange(frequency: .continuous) { context in
            // Capture map heading and distance
            mapHeading = context.camera.heading
            cameraDistance = context.camera.distance
            
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
        .task(id: defaultZoomLevelRaw) {
            // Re-sync camera when view becomes active or zoom changes
            // This handles returning from Settings where onAppear may not fire
            if let location = stateMachine.currentLocation, trackingMode != .free {
                updateCamera(for: location)
            }
        }
    }
    
    // MARK: - Extracted Sub-views (for compiler type-checking)
    
    /// The main map view with all annotations and overlays
    private var mapView: some View {
        Map(position: $cameraPosition) {
            mapContent
        }
        .mapStyle(.standard(elevation: .realistic))
        .mapControls {
            // Empty - we position compass manually
        }
        .mapScope(mapScope)
        .ignoresSafeArea()
    }
    
    /// Map content builder - calls sub-builders for each layer
    @MapContentBuilder
    private var mapContent: some MapContent {
        placesContent
        historyContent
        puckContent
        routeContent
    }
    
    /// Places layer - circles and annotations
    @MapContentBuilder
    private var placesContent: some MapContent {
        if shouldShowPlaces {
            ForEach(savedPlaces) { place in
                placeCircle(for: place)
            }
            ForEach(savedPlaces) { place in
                placeAnnotation(for: place)
            }
        }
    }
    
    /// Single place circle - extracted for type-checking
    private func placeCircle(for place: Place) -> some MapContent {
        MapCircle(center: place.coordinate, radius: place.radiusMeters)
            .foregroundStyle(placeColor(for: place.icon).opacity(0.15))
            .stroke(placeColor(for: place.icon).opacity(0.4), lineWidth: 1.5)
    }
    
    /// History routes layer
    @MapContentBuilder
    private var historyContent: some MapContent {
        let sortedRoutes = historyRouteCache.sorted { $0.value.endTime < $1.value.endTime }
        ForEach(sortedRoutes, id: \.key) { driveId, route in
            MapPolyline(coordinates: route.coordinates)
                .stroke(historyRouteColor(for: driveId), lineWidth: 5)
        }
    }
    
    /// Navigation puck layer - using Apple's native UserLocation for stability
    @MapContentBuilder
    private var puckContent: some MapContent {
        // Apple's native user location puck - handles all interpolation internally
        UserAnnotation()
        
        // Accuracy ring using stateMachine location
        if let location = stateMachine.currentLocation,
           location.horizontalAccuracy > 0 {
            MapCircle(center: location.coordinate, radius: min(location.horizontalAccuracy, 150))
                .foregroundStyle(Color.blue.opacity(0.08))
                .stroke(Color.blue.opacity(0.25), lineWidth: 1.5)
        }
    }
    
    /// Active drive route layer
    @MapContentBuilder
    private var routeContent: some MapContent {
        if !routeCoordinates.isEmpty {
            MapPolyline(coordinates: routeCoordinates)
                .stroke(.blue, lineWidth: 6)
        }
    }
    
    /// Place annotation with optional dwell bubble - extracted for type-checking
    private func placeAnnotation(for place: Place) -> some MapContent {
        let isActiveDwell = activeDwellPlace?.id == place.id
        return Annotation(place.name, coordinate: place.coordinate, anchor: .bottom) {
            Button {
                selectedPlaceForDwell = place
            } label: {
                PlaceMarkerView(icon: place.icon, color: placeColor(for: place.icon))
            }
            .buttonStyle(.plain)
            .overlay(alignment: .top) {
                if isActiveDwell {
                    dwellBubble
                        .fixedSize()  // Prevent clipping to parent size
                        .offset(y: -50)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        .allowsHitTesting(false)
                }
            }
        }
        .annotationTitles(.hidden)
    }
    
    /// Dwell status bubble - extracted for type-checking
    @ViewBuilder
    private var dwellBubble: some View {
        if let dwell = stateMachine.activeDwellSummary {
            DwellStatusBubble(
                placeName: dwell.placeName,
                placeIcon: dwell.placeIcon,
                arrivalTime: dwell.arrivalTime,
                isEstimated: false
            )
        } else if let softDwell {
            DwellStatusBubble(
                placeName: softDwell.placeName,
                placeIcon: softDwell.placeIcon,
                arrivalTime: softDwell.startedAt,
                isEstimated: true
            )
        }
    }
    
    /// Controls overlay (speed HUD, location button, compass)
    private var controlsOverlay: some View {
        // Use dynamic height from environment, but enforce minimum 112 (peek height)
        // This ensures expanding the sheet pushes the controls up
        let effectiveBarHeight = max(bottomBarHeight, 112)
        
        return VStack {
            // Top row: Speed HUD (visible when driving)
            HStack {
                if stateMachine.state == .driving || stateMachine.state == .maybeDriving {
                    SpeedHUD(speed: stateMachine.currentSpeedMPH)  // Already in MPH from stateMachine
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .animation(.easeInOut(duration: 0.3), value: stateMachine.state)
            
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
            // Position above BottomBar
            // Both controlsOverlay and BottomBar respect safe area (sit above home indicator)
            // So we just need to clear the content height of the bar.
            .padding(.bottom, effectiveBarHeight + 12)
            // Animate only the layout changes (margin updates)
            // REMOVED: .animation(.spring(...))
            // We want direct tracking because the source value (bottomBarHeight) 
            // is already animated or gesture-driven. Double-animating causes lag/stuck behavior.
        }
    }

    // MARK: - Soft Dwell (UI-only)

    private func updateSoftDwellIfNeeded(currentLocation location: CLLocation) {
        // If there's an authoritative active PlaceVisit, don't show an estimated one.
        guard stateMachine.activeDwellSummary == nil else {
            softDwell = nil
            softDwellCandidate = nil
            return
        }

        let now = Date()

        // Tunables (aim: reduce drive-by false positives and boundary jitter)
        let entryAccuracyMeters: CLLocationAccuracy = 60
        let exitAccuracyMeters: CLLocationAccuracy = 120
        let entryBufferMeters: CLLocationDistance = 15
        let exitBufferMeters: CLLocationDistance = 25
        let confirmSecondsSpeedKnown: TimeInterval = 12
        let confirmSecondsSpeedUnknown: TimeInterval = 20
        let exitSpeedMPH: CLLocationSpeed = 10

        let accuracy = location.horizontalAccuracy
        let accuracyValid = accuracy > 0
        let speedKnown = location.speed >= 0
        let speedMPH = speedKnown ? (location.speed * 2.23694) : 0

        // Fast exit conditions if we already have a soft dwell.
        if let soft = softDwell {
            guard let place = placeForSoftDwellKey(soft.key) else {
                softDwell = nil
                softDwellCandidate = nil
                return
            }

            let distance = place.distance(to: location.coordinate)
            let radius = place.radiusMeters
            let stillInside = distance <= (radius + exitBufferMeters)
            let accuracyOK = accuracyValid && accuracy <= exitAccuracyMeters
            let speedOK = !speedKnown || speedMPH <= exitSpeedMPH

            if stillInside && accuracyOK && speedOK {
                return
            }

            softDwell = nil
            softDwellCandidate = nil
            return
        }

        // Entry path: require a reasonably good fix, and being well-inside a place radius.
        guard accuracyValid, accuracy <= entryAccuracyMeters else {
            softDwellCandidate = nil
            return
        }

        guard let (place, distance) = bestMatchingPlaceAndDistance(for: location.coordinate, places: savedPlaces) else {
            softDwellCandidate = nil
            return
        }

        let radius = place.radiusMeters
        let entryThreshold = max(0, radius - entryBufferMeters)
        guard distance <= entryThreshold else {
            softDwellCandidate = nil
            return
        }

        let key = softDwellKey(for: place)
        if softDwellCandidate?.key != key {
            softDwellCandidate = SoftDwellCandidate(
                key: key,
                placeName: place.name,
                placeIcon: place.icon,
                firstSeenAt: now,
                lastSeenAt: now
            )
            return
        }

        softDwellCandidate?.lastSeenAt = now

        let confirmSeconds = speedKnown ? confirmSecondsSpeedKnown : confirmSecondsSpeedUnknown
        if let candidate = softDwellCandidate, now.timeIntervalSince(candidate.firstSeenAt) >= confirmSeconds {
            softDwell = SoftDwell(
                key: candidate.key,
                placeName: candidate.placeName,
                placeIcon: candidate.placeIcon,
                startedAt: candidate.firstSeenAt
            )
            softDwellCandidate = nil
        }
    }

    private func bestMatchingPlaceAndDistance(
        for coordinate: CLLocationCoordinate2D,
        places: [Place]
    ) -> (Place, CLLocationDistance)? {
        let containing = places.filter { $0.contains(coordinate) }
        guard let best = containing.min(by: { $0.distance(to: coordinate) < $1.distance(to: coordinate) }) else {
            return nil
        }
        return (best, best.distance(to: coordinate))
    }

    private func placeForSoftDwellKey(_ key: String) -> Place? {
        savedPlaces.first { softDwellKey(for: $0) == key }
    }

    private func softDwellKey(for place: Place) -> String {
        "\(place.name)|\(place.latitude)|\(place.longitude)|\(place.radiusMeters)"
    }
    
    // MARK: - Camera Updates
    
    private func updateCamera(for location: CLLocation) {
        let heading = resolvedHeading(for: location)
        let camera = mapCamera(
            for: trackingMode,
            location: location,
            speed: location.speed,
            zoomLevel: zoomLevel,
            headingOverride: heading
        )
        
        // Use interactiveSpring for smooth, natural motion
        withAnimation(.interactiveSpring(response: 0.15, dampingFraction: 0.9)) {
            cameraPosition = .camera(camera)
        }
        
        lastCameraUpdate = Date()
    }
    
    /// Camera update driven by GPS location directly (no interpolator)
    private func updateCameraFromLocation(location: CLLocation, heading: Double) {
        let coordinate = location.coordinate
        let camera: MapCamera
        
        switch trackingMode {
        case .free:
            // Shouldn't reach here, but return safe fallback
            return
            
        case .follow:
            camera = MapCamera(
                centerCoordinate: coordinate,
                distance: zoomLevel.distance,
                heading: 0,
                pitch: 0
            )
            
        case .followWithHeading:
            camera = MapCamera(
                centerCoordinate: coordinate,
                distance: zoomLevel.distance,
                heading: heading,
                pitch: 0
            )
            
        case .drivingView:
            // Look-ahead: project center 120m forward
            let centerAhead = coordinate.projected(
                distance: 120,
                bearing: heading
            )
            
            // Pitch follows speed (only tilt when moving fast)
            let speedMPH = stateMachine.currentSpeedMPH
            let pitch: Double = speedMPH >= 5 ? 60 : 0
            
            camera = MapCamera(
                centerCoordinate: centerAhead,
                distance: zoomLevel.drivingDistance,
                heading: heading,
                pitch: pitch
            )
        }
        
        // Apply camera update with smooth animation
        // GPS updates at ~1Hz - spring animation interpolates smoothly between positions
        withAnimation(.interactiveSpring(response: 0.4, dampingFraction: 0.85)) {
            cameraPosition = .camera(camera)
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
        case .follow, .followWithHeading, .drivingView: return .blue
        }
    }
    
    private func handleLocationButtonTap() {
        guard let location = stateMachine.currentLocation else { return }
        
        withAnimation {
            switch trackingMode {
            case .free:
                // From free → follow (center on user)
                trackingMode = .follow
            case .follow:
                // From follow → heading (rotate map with direction)
                trackingMode = .followWithHeading
            case .followWithHeading:
                if stateMachine.state == .driving || stateMachine.state == .maybeDriving {
                    // From heading → cinematic driving view
                    trackingMode = .drivingView
                } else {
                    // From heading → back to free (exit tracking)
                    trackingMode = .free
                }
            case .drivingView:
                // If somehow in drivingView, go back to free
                trackingMode = .free
            }
            
            updateCamera(for: location)
        }
    }

    private func resolvedHeading(for location: CLLocation) -> Double {
        let speedMPH = max(0, location.speed * 2.23694)
        let course = location.course
        let hasValidCourse = course >= 0

        if hasValidCourse && speedMPH >= minSpeedForHeadingMPH {
            let target = normalizeHeading(course)
            if !hasCourseHeading {
                lastCourseHeading = target
                hasCourseHeading = true
            } else {
                let delta = shortestAngleDelta(from: lastCourseHeading, to: target)
                lastCourseHeading = normalizeHeading(lastCourseHeading + headingSmoothingAlpha * delta)
            }
        }

        return hasCourseHeading ? lastCourseHeading : 0
    }

    private func normalizeHeading(_ angle: Double) -> Double {
        let value = angle.truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }

    private func shortestAngleDelta(from: Double, to: Double) -> Double {
        var delta = normalizeHeading(to) - normalizeHeading(from)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
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
    
    // MARK: - History Cache Helper
    
    private func updateHistoryCache() {
        // Run as a task on MainActor (since accessing SwiftData models)
        // But yield to allow UI responsiveness
        Task {
            guard let windowStart = historyTimeSpan.windowStart else {
                withAnimation {
                    historyRouteCache = [:]
                }
                return
            }
            
            let now = Date()
            // Filter drives first
            let drivesToCache = allDrives.filter { drive in
                guard drive.id != stateMachine.activeDrive?.id else { return false }
                guard let endTime = drive.endTime else { return false }
                return endTime >= windowStart && drive.startTime <= now
            }
            
            var newCache: [UUID: HistoryRoute] = [:]
            
            for drive in drivesToCache {
                // Accessing pointsChronological triggers sorting on Main Thread
                // We yield every few drives to keep UI responsive
                let coords = drive.pointsChronological.map { $0.coordinate }
                newCache[drive.id] = HistoryRoute(
                    coordinates: coords,
                    endTime: drive.endTime ?? drive.startTime
                )
                await Task.yield()
            }
            
            // Only update if we are still relevant (optional check)
            withAnimation {
                self.historyRouteCache = newCache
            }
        }
    }

    private func historyRouteColor(for driveId: UUID) -> Color {
        let hue = driveHue(for: driveId)
        return Color(hue: hue, saturation: 0.7, brightness: 0.9)
    }

    private func driveHue(for driveId: UUID) -> Double {
        // Stable hash -> hue (0...1)
        let bytes = Array(driveId.uuidString.utf8)
        var hash: UInt32 = 2166136261
        for byte in bytes {
            hash ^= UInt32(byte)
            hash &*= 16777619
        }
        return Double(hash % 360) / 360.0
    }
}

private struct HistoryRoute {
    let coordinates: [CLLocationCoordinate2D]
    let endTime: Date
}

// MARK: - Dwell Status Bubble

private struct DwellStatusBubble: View {
    let placeName: String
    let placeIcon: String
    let arrivalTime: Date
    let isEstimated: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            HStack(spacing: 8) {
                Image(systemName: placeIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.95))

                VStack(alignment: .leading, spacing: 1) {
                    Text(placeName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(subtitle(now: now))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.8))
                        .monospacedDigit()
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.black.opacity(0.65))
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.ultraThinMaterial)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(.white.opacity(0.12), lineWidth: 1)
                    )
            )
        }
    }

    private func subtitle(now: Date) -> String {
        let duration = formatDuration(now.timeIntervalSince(arrivalTime))
        if isEstimated {
            return "Here ~\(duration)"
        }
        return "Here for \(duration)"
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let hours = s / 3600
        let minutes = (s % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}

private struct SoftDwell {
    let key: String
    let placeName: String
    let placeIcon: String
    let startedAt: Date
}

private struct SoftDwellCandidate {
    let key: String
    let placeName: String
    let placeIcon: String
    let firstSeenAt: Date
    var lastSeenAt: Date
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

// MARK: - Speed HUD

struct SpeedHUD: View {
    let speed: Double
    
    private var displaySpeed: Int {
        max(0, Int(round(speed)))
    }
    
    var body: some View {
        VStack(spacing: 2) {
            Text("\(displaySpeed)")
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .monospacedDigit()
            
            Text("MPH")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.8))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.6))
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        )
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

// MARK: - Place Marker View

struct PlaceMarkerView: View {
    let icon: String
    let color: Color
    
    var body: some View {
        ZStack {
            // Shadow/glow effect
            Circle()
                .fill(color.opacity(0.3))
                .frame(width: 44, height: 44)
            
            // Main circle background
            Circle()
                .fill(color)
                .frame(width: 36, height: 36)
                .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
            
            // Icon
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
        }
    }
}

// MARK: - Place Color Helper

func placeColor(for icon: String) -> Color {
    switch icon {
    case "house.fill":
        return .green
    case "building.2.fill":
        return .blue
    case "figure.run":
        return .orange
    case "graduationcap.fill":
        return .purple
    case "cart.fill":
        return .pink
    case "fork.knife":
        return .red
    case "fuelpump.fill":
        return .yellow
    case "cross.fill":
        return .red
    case "leaf.fill":
        return .mint
    default:
        return .gray
    }
}

#Preview {
    DashboardView(
        stateMachine: DriveStateMachine(),
        locationManager: LocationManager()
    )
}
