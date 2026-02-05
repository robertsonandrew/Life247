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
    @Binding var selectedHistoryRoute: HistoryRouteSelection?
    @Binding var bottomBarDetent: BottomBarDetent
    @Query(sort: \Drive.startTime, order: .reverse) private var allDrives: [Drive]
    @Query private var savedPlaces: [Place]
    @AppStorage("defaultZoomLevel") private var defaultZoomLevelRaw: String = MapZoomLevel.area.rawValue
    @AppStorage("showPlacesOnMap") private var showPlacesOnMap = true
    @AppStorage("showPlaceCenterMarkers") private var showPlaceCenterMarkers = false
    @AppStorage("showMapStyleButton") private var showMapStyleButton = false
    @AppStorage("mapVisualStyle") private var mapVisualStyleRaw: String = MapVisualStyle.standard.rawValue
    @Environment(\.bottomBarHeight) private var bottomBarHeight

    let isVisible: Bool
    
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var trackingMode: MapTrackingMode = .follow
    @State private var mapHeading: Double = 0
    @State private var cameraDistance: Double = 800  // meters from ground
    @State private var mapPitch: Double = 0
    @State private var mapCenterCoordinate: CLLocationCoordinate2D?
    @GestureState private var isMapPinchActive = false
    @State private var lastCameraUpdate: Date = .distantPast
    @State private var lastHeadingCameraUpdate: Date = .distantPast
    @State private var lastCourseHeading: Double = 0
    @State private var hasCourseHeading: Bool = false
    @State private var liveResolvedHeading: Double?
    @State private var puckRenderNonce: Int = 0
    @AppStorage("historyTimeSpan") private var historyTimeSpanRaw: String = HistoryTimeSpan.off.rawValue
    @State private var routeCoordinates: [CLLocationCoordinate2D] = []  // Cached for stable polyline
    @State private var showMapStyleSheet = false
    // REMOVED: @State private var interpolator = LocationInterpolator() - map is driven directly by GPS updates
    @Namespace private var mapScope

    @State private var selectedPlaceForDwell: Place?

    @State private var softDwell: SoftDwell?
    @State private var softDwellCandidate: SoftDwellCandidate?
    
    // Cache for history routes to prevent re-sorting on every frame
    @State private var historyRouteCache: [UUID: HistoryRoute] = [:]
    @State private var routeFocusTask: Task<Void, Never>?
    @State private var lastFocusedRouteId: UUID?
    
    private var historyTimeSpan: HistoryTimeSpan {
        HistoryTimeSpan(rawValue: historyTimeSpanRaw) ?? .off
    }
    
    private var zoomLevel: MapZoomLevel {
        MapZoomLevel(rawValue: defaultZoomLevelRaw) ?? .area
    }

    private let minSpeedForHeadingMPH: Double = 3.0
    private let headingSmoothingAlphaCourse: Double = 0.25
    private let headingSmoothingAlphaCompass: Double = 0.45
    private let headingUpdateThresholdDegrees: Double = 1.5
    private let minHeadingUpdateInterval: TimeInterval = 0.08
    private let routeFocusSheetFirstDelayMs: UInt64 = 140
    private let routeFocusAnimationDuration: TimeInterval = 0.42
    private let routeRefitAnimationDuration: TimeInterval = 0.25
    private let routeFocusMinSpanDelta: Double = 0.004
    private let routeFocusPaddingFactor: Double = 1.22

    enum MapVisualStyle: String, CaseIterable {
        case standard
        case hybrid
        case satellite

        var title: String {
            switch self {
            case .standard: return "Default"
            case .hybrid: return "Hybrid"
            case .satellite: return "Satellite"
            }
        }

        var subtitle: String {
            switch self {
            case .standard: return "Road map"
            case .hybrid: return "Roads + imagery"
            case .satellite: return "Imagery"
            }
        }
    }

    private var mapVisualStyle: MapVisualStyle {
        get { MapVisualStyle(rawValue: mapVisualStyleRaw) ?? .standard }
        nonmutating set { mapVisualStyleRaw = newValue.rawValue }
    }

    private var activeMapStyle: MapStyle {
        switch mapVisualStyle {
        case .standard:
            return .standard(elevation: .realistic)
        case .hybrid:
            return .hybrid(elevation: .realistic)
        case .satellite:
            return .imagery(elevation: .realistic)
        }
    }
    
    /// Only show saved places when setting is enabled AND camera is at reasonable zoom level
    private var shouldShowPlaces: Bool {
        showPlacesOnMap && cameraDistance < 50000  // ~30 miles - hides when zoomed way out
    }

    private struct PlaceCircleStyle {
        let fillOpacity: Double
        let haloOpacity: Double
        let strokeOpacity: Double
        let strokeWidth: CGFloat
        let coreOpacity: Double
        let coreStrokeOpacity: Double
        let coreStrokeWidth: CGFloat
        let coreScale: Double
    }

    private var placeCircleStyle: PlaceCircleStyle {
        // Normalize visual density by zoom distance so geofences remain readable.
        switch cameraDistance {
        case ..<1200:
            return PlaceCircleStyle(
                fillOpacity: 0.16,
                haloOpacity: 0.22,
                strokeOpacity: 0.72,
                strokeWidth: 2.6,
                coreOpacity: 0.18,
                coreStrokeOpacity: 0.62,
                coreStrokeWidth: 1.6,
                coreScale: 0.20
            )
        case ..<5000:
            return PlaceCircleStyle(
                fillOpacity: 0.14,
                haloOpacity: 0.19,
                strokeOpacity: 0.62,
                strokeWidth: 2.2,
                coreOpacity: 0.16,
                coreStrokeOpacity: 0.54,
                coreStrokeWidth: 1.4,
                coreScale: 0.17
            )
        case ..<18000:
            return PlaceCircleStyle(
                fillOpacity: 0.11,
                haloOpacity: 0.15,
                strokeOpacity: 0.48,
                strokeWidth: 1.8,
                coreOpacity: 0.14,
                coreStrokeOpacity: 0.44,
                coreStrokeWidth: 1.2,
                coreScale: 0.14
            )
        default:
            return PlaceCircleStyle(
                fillOpacity: 0.08,
                haloOpacity: 0.12,
                strokeOpacity: 0.36,
                strokeWidth: 1.4,
                coreOpacity: 0.12,
                coreStrokeOpacity: 0.36,
                coreStrokeWidth: 1.0,
                coreScale: 0.12
            )
        }
    }

    private var isDriveInteractionLocked: Bool {
        switch stateMachine.state {
        case .maybeDriving, .driving, .stopped, .pendingArrival:
            return true
        case .idle, .ended:
            return false
        }
    }

    private var canSelectHistoryRoutes: Bool {
        !isDriveInteractionLocked && historyTimeSpan != .off && !historyRouteCache.isEmpty
    }
    
    private var shouldShowCompassControl: Bool {
        let normalized = normalizeHeading(mapHeading)
        let offNorthDegrees = min(normalized, 360 - normalized)
        let headingMode = trackingMode == .followWithHeading || trackingMode == .drivingView
        return headingMode || offNorthDegrees > 3
    }

    private var isHeadingTrackingMode: Bool {
        trackingMode == .followWithHeading || trackingMode == .drivingView
    }

    private var routeSelectionThresholdMeters: Double {
        // Scale with zoom: tighter when zoomed in, more forgiving when zoomed out
        let scaled = cameraDistance * 0.02
        return min(60, max(15, scaled))
    }

    private var headingConeScale: CGFloat {
        // Keep cone legible across zoom levels; slightly larger when zoomed in.
        switch cameraDistance {
        case ..<250: return 1.7
        case ..<600: return 1.5
        case ..<1200: return 1.35
        case ..<3000: return 1.2
        default: return 1.0
        }
    }
    
    // Camera updates are driven directly by stateMachine.currentLocation.
    // Puck/cone rendering uses a custom annotation to keep icon + cone in sync.
    
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
        dashboardContent
    }

    private var dashboardContent: some View {
        dashboardContentWithLifecycle
            .task {
                if isVisible {
                    updateHistoryCache()
                }
            }
            .onMapCameraChange(frequency: .continuous) { context in
                // Threshold updates to reduce state churn and re-renders
                let newHeading = context.camera.heading
                if abs(shortestAngleDelta(from: mapHeading, to: newHeading)) > 0.5 {
                    mapHeading = newHeading
                }

                let newDistance = context.camera.distance
                if abs(newDistance - cameraDistance) > 10 {
                    cameraDistance = newDistance
                }

                let newPitch = context.camera.pitch
                if abs(newPitch - mapPitch) > 2 {
                    mapPitch = newPitch
                }

                let newCenter = context.camera.centerCoordinate
                if let oldCenter = mapCenterCoordinate {
                    // Update center only if moved more than ~2 meters
                    if centerDistanceMeters(from: oldCenter, to: newCenter) > 5 {
                        mapCenterCoordinate = newCenter
                    }
                } else {
                    mapCenterCoordinate = newCenter
                }
            }
            .simultaneousGesture(pinchObservationGesture)
            .simultaneousGesture(trackingDisengagePanGesture)
            .task(id: defaultZoomLevelRaw) {
                // Re-sync camera when view becomes active or zoom changes
                // This handles returning from Settings where onAppear may not fire
                if isVisible, let location = stateMachine.currentLocation, trackingMode != .free {
                    updateCamera(for: location)
                }
            }
    }

    private var dashboardContentWithLifecycle: some View {
        dashboardContentWithCoreChanges
            .onChange(of: bottomBarDetent) { oldDetent, newDetent in
                guard let selection = selectedHistoryRoute else { return }
                guard routeFocusTask == nil else { return }
                guard newDetent.rawValue > oldDetent.rawValue else { return }
                focusCamera(
                    on: selection.id,
                    detent: newDetent,
                    animated: true,
                    duration: routeRefitAnimationDuration
                )
            }
            .onChange(of: selectedHistoryRoute?.id) { _, newId in
                if newId == nil {
                    cancelRouteFocusTask()
                    lastFocusedRouteId = nil
                }
            }
            .onChange(of: isVisible) { _, visible in
                if !visible {
                    cancelRouteFocusTask()
                }
            }
    }

    private var dashboardContentWithCoreChanges: some View {
        dashboardContentBase
            .sheet(item: $selectedPlaceForDwell) { place in
                NavigationStack {
                    PlaceDwellView(place: place)
                }
            }
            .sheet(isPresented: $showMapStyleSheet) {
                mapStyleSheet
            }
            .onAppear { handleOnAppear() }
            .onChange(of: isVisible) { _, visible in
                if visible {
                    puckRenderNonce &+= 1
                    if isHeadingTrackingMode {
                        primeHeadingConeIfNeeded()
                    }
                    updateHistoryCache()
                }
            }
            // Use .task for route initialization - runs before first render, guaranteed
            .task { if isVisible { initializeRouteCacheFromActiveDrive() } }
            .onChange(of: stateMachine.currentLocation) { _, newLocation in
                guard isVisible else { return }
                handleLocationChange(newLocation)
            }
            .onChange(of: stateMachine.state) { oldState, newState in
                // Keep tracking-mode transitions in sync even when map tab is hidden.
                // Camera writes remain visibility-gated inside updateCamera/updateCameraFromLocation.
                handleDriveStateChange(from: oldState, to: newState)
            }
            .onChange(of: trackingMode) { _, newMode in
                guard isVisible else { return }
                puckRenderNonce &+= 1
                if newMode == .followWithHeading || newMode == .drivingView {
                    primeHeadingConeIfNeeded()
                }
            }
            // Heading updates only needed for compass display, not for camera
            .onChange(of: locationManager.currentHeading) { _, newHeading in
                guard isVisible else { return }
                handleHeadingChange(newHeading)
            }
            .onChange(of: stateMachine.activeDrive?.points.count) { _, _ in
                guard isVisible else { return }
                syncActiveRoutePoints()
            }
            .onChange(of: defaultZoomLevelRaw) { _, _ in
                guard isVisible else { return }
                handleZoomSettingChange()
            }
            // Update history cache when history span changes or drives change
            .onChange(of: historyTimeSpan) { _, _ in
                if isVisible {
                    updateHistoryCache()
                }
            }
            .onChange(of: allDrives.count) { _, _ in
                if isVisible {
                    updateHistoryCache()
                }
            }
    }

    private var dashboardContentBase: some View {
        ZStack {
            mapView
            controlsOverlay
        }
    }

    private var mapStyleSheet: some View {
        MapStylePickerSheet(
            selectedStyle: mapVisualStyle,
            onSelect: { style in
                mapVisualStyle = style
                showMapStyleSheet = false
            },
            onClose: { showMapStyleSheet = false }
        )
        .presentationDetents([.height(280), .medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(.ultraThinMaterial)
    }

    private var pinchObservationGesture: some Gesture {
        MagnificationGesture()
            .updating($isMapPinchActive) { _, state, _ in
                state = true
            }
    }

    private var trackingDisengagePanGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                // Keep heading/follow active while pinching, matching common navigation UX.
                guard !isMapPinchActive else { return }
                let translation = hypot(value.translation.width, value.translation.height)
                guard translation > 22 else { return }
                guard trackingMode != .free else { return }
                trackingMode = .free
            }
    }
    
    // MARK: - Extracted Sub-views (for compiler type-checking)
    
    /// The main map view with all annotations and overlays
    private var mapView: some View {
        MapReader { proxy in
            Map(position: $cameraPosition) {
                mapContent
            }
            .mapStyle(activeMapStyle)
            .mapControls {
                // Intentionally empty — custom-positioned compass overlay is used
            }
            .mapScope(mapScope)
            .ignoresSafeArea()
            .gesture(
                SpatialTapGesture()
                    .onEnded { value in
                        guard isVisible else { return }
                        guard canSelectHistoryRoutes else { return }
                        if let coordinate = proxy.convert(value.location, from: .local) {
                            handleHistoryRouteTap(at: coordinate)
                        }
                    }
            )
        }
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
            if showPlaceCenterMarkers {
                ForEach(savedPlaces) { place in
                    if place.id != activeDwellPlace?.id {
                        placeCenterMarker(for: place)
                    }
                }
            }
            if let activePlace = activeDwellPlace {
                activeDwellAnnotation(for: activePlace)
            }
        }
    }
    
    /// Geofence circles with zoom-adaptive styling.
    @MapContentBuilder
    private func placeCircle(for place: Place) -> some MapContent {
        let style = placeCircleStyle
        let color = placeColor(for: place.icon)
        let coreRadius = max(10, min(place.radiusMeters * style.coreScale, 65))
        
        MapCircle(center: place.coordinate, radius: place.radiusMeters)
            .foregroundStyle(color.opacity(style.fillOpacity))
            .stroke(.white.opacity(style.haloOpacity), lineWidth: style.strokeWidth + 1.2)
            .stroke(color.opacity(style.strokeOpacity), lineWidth: style.strokeWidth)
        
        MapCircle(center: place.coordinate, radius: coreRadius)
            .foregroundStyle(color.opacity(style.coreOpacity))
            .stroke(color.opacity(style.coreStrokeOpacity), lineWidth: style.coreStrokeWidth)
        
        if activeDwellPlace?.id == place.id {
            MapCircle(center: place.coordinate, radius: place.radiusMeters + 16)
                .stroke(.white.opacity(0.32), lineWidth: 1.5)
        }
    }

    private func placeCenterMarker(for place: Place) -> some MapContent {
        Annotation(place.name, coordinate: place.coordinate, anchor: .center) {
            Circle()
                .fill(.white.opacity(0.9))
                .frame(width: 6, height: 6)
                .overlay(
                    Circle()
                        .stroke(.white.opacity(0.45), lineWidth: 1)
                        .frame(width: 12, height: 12)
                )
                .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
        }
        .annotationTitles(.hidden)
    }
    
    /// History routes layer
    @MapContentBuilder
    private var historyContent: some MapContent {
        let selectedId = selectedHistoryRoute?.id
        let sortedRoutes = historyRouteCache.sorted { $0.value.endTime < $1.value.endTime }
        let indexedRoutes = Array(sortedRoutes.enumerated())
        
        ForEach(indexedRoutes, id: \.element.key) { indexedRoute in
            let driveId = indexedRoute.element.key
            let route = indexedRoute.element.value
            if driveId != selectedId {
                let hue = historyRouteHue(for: indexedRoute.offset, total: sortedRoutes.count)
                let opacity = historyRouteOpacity(for: route.endTime)
                MapPolyline(coordinates: route.coordinates)
                    .stroke(historyRouteColor(hue: hue, opacity: opacity), lineWidth: 5)
            }
        }
        
        if let selectedId,
           let indexedRoute = indexedRoutes.first(where: { $0.element.key == selectedId }) {
            let hue = historyRouteHue(for: indexedRoute.offset, total: sortedRoutes.count)
            let route = indexedRoute.element.value
            let baseColor = historyRouteColor(hue: hue, opacity: 1.0)
            
            // Static glow (MapContent doesn't support animation modifiers)
            MapPolyline(coordinates: route.coordinates)
                .stroke(baseColor.opacity(0.30), lineWidth: 14)
            MapPolyline(coordinates: route.coordinates)
                .stroke(baseColor.opacity(0.96), lineWidth: 8)
        }
    }
    
    /// Navigation puck layer
    @MapContentBuilder
    private var puckContent: some MapContent {
        if isVisible {
            // Accuracy ring using stateMachine location (draw first so puck/cone stay visible on top)
            if let location = stateMachine.currentLocation,
               location.horizontalAccuracy > 0 {
                MapCircle(center: location.coordinate, radius: min(location.horizontalAccuracy, 150))
                    .foregroundStyle(Color.blue.opacity(0.08))
                    .stroke(Color.blue.opacity(0.25), lineWidth: 1.5)
            }

            // Render puck + cone in one annotation view so they stay phase-aligned.
            let coneLocation = stateMachine.currentLocation
            let showCone = isHeadingTrackingMode
            let speedMPS = max(0, coneLocation?.speed ?? 0)
            if let location = coneLocation {
                let headingValue = liveResolvedHeading ?? currentDeviceHeading() ?? normalizeHeading(mapHeading)
                let annotationKey = "puck-\(showCone ? "heading" : "follow")-\(puckRenderNonce)"
                if showCone {
                    Annotation(annotationKey, coordinate: location.coordinate, anchor: .center) {
                        PuckWithHeadingOverlay(
                            showCone: true,
                            heading: headingValue,
                            mapHeading: mapHeading,
                            speedMPS: speedMPS,
                            coneScale: headingConeScale
                        )
                        .allowsHitTesting(false)
                    }
                    .annotationTitles(.hidden)
                } else {
                    Annotation(annotationKey, coordinate: location.coordinate, anchor: .center) {
                        PuckWithHeadingOverlay(
                            showCone: false,
                            heading: headingValue,
                            mapHeading: mapHeading,
                            speedMPS: speedMPS,
                            coneScale: headingConeScale
                        )
                        .allowsHitTesting(false)
                    }
                    .annotationTitles(.hidden)
                }
            }
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
    
    /// Minimal active-place marker used only to anchor dwell bubble (no place icon).
    private func activeDwellAnnotation(for place: Place) -> some MapContent {
        return Annotation(place.name, coordinate: place.coordinate, anchor: .bottom) {
            Button {
                selectedPlaceForDwell = place
            } label: {
                Circle()
                    .fill(.white.opacity(0.95))
                    .frame(width: 9, height: 9)
                    .overlay(
                        Circle()
                            .stroke(.white.opacity(0.5), lineWidth: 1)
                            .frame(width: 16, height: 16)
                    )
            }
            .buttonStyle(.plain)
            .overlay(alignment: .top) {
                dwellBubble
                    .fixedSize()  // Prevent clipping to parent size
                    .offset(y: -24)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
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
                    // Match Apple Maps behavior: show compass when rotated, and always in heading modes.
                    if shouldShowCompassControl {
                        compassControl
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }

                    controlPill
                }
                .animation(.easeInOut(duration: 0.2), value: shouldShowCompassControl)
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

    @ViewBuilder
    private var controlPill: some View {
        VStack(spacing: 10) {
            if showMapStyleButton {
                Button {
                    showMapStyleSheet = true
                } label: {
                    Image(systemName: "map")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .frame(width: 56, height: 56)
                        .background(
                            Circle()
                                .fill(.black.opacity(0.52))
                                .background(Circle().fill(.ultraThinMaterial))
                        )
                        .overlay(
                            Circle()
                                .stroke(.white.opacity(0.15), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)
                }
                .buttonStyle(.plain)
            }

            Button(action: handleLocationButtonTap) {
                Image(systemName: trackingModeIcon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(trackingModeColor)
                    .frame(width: 56, height: 56)
                    .background(
                        Circle()
                            .fill(.black.opacity(0.52))
                            .background(Circle().fill(.ultraThinMaterial))
                    )
                    .overlay(
                        Circle()
                            .stroke(.white.opacity(0.15), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)
            }
            .buttonStyle(.plain)
        }
    }

    private func handleOnAppear() {
        guard isVisible else { return }
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

    private func initializeRouteCacheFromActiveDrive() {
        if let drive = stateMachine.activeDrive {
            routeCoordinates = drive.pointsChronological.map { $0.coordinate }
        }
    }

    private func handleLocationChange(_ newLocation: CLLocation?) {
        guard let location = newLocation else { return }
        let heading = refreshResolvedHeading(for: location)
        
        // Update camera directly from GPS location (no interpolator needed)
        if trackingMode != .free {
            updateCameraFromLocation(location: location, heading: heading)
        }

        updateSoftDwellIfNeeded(currentLocation: location)
    }

    private func handleHeadingChange(_ newHeading: CLHeading?) {
        guard trackingMode == .followWithHeading || trackingMode == .drivingView else { return }
        guard newHeading != nil, let location = stateMachine.currentLocation else { return }

        let now = Date()
        guard now.timeIntervalSince(lastHeadingCameraUpdate) >= minHeadingUpdateInterval else { return }

        let heading = refreshResolvedHeading(for: location)
        let delta = abs(shortestAngleDelta(from: mapHeading, to: heading))
        guard delta >= headingUpdateThresholdDegrees else { return }

        lastHeadingCameraUpdate = now
        updateCameraForHeadingChange(location: location, heading: heading)
    }

    private func syncActiveRoutePoints() {
        // Update cached route only when points change
        guard let drive = stateMachine.activeDrive else {
            routeCoordinates = []
            return
        }
        routeCoordinates = drive.pointsChronological.map { $0.coordinate }
    }

    private func handleDriveStateChange(from _: DriveState, to newState: DriveState) {
        if newState == .driving || newState == .maybeDriving || newState == .stopped || newState == .pendingArrival {
            selectedHistoryRoute = nil
        }

        if newState == .driving || newState == .maybeDriving {
            // Auto-rotate map when driving (if user hasn't panned away)
            if trackingMode == .follow {
                trackingMode = .followWithHeading
                if let location = stateMachine.currentLocation {
                    updateCamera(for: location)
                }
            } else if trackingMode == .free {
                // Enter driving camera automatically when a drive begins from free mode.
                trackingMode = .drivingView
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

    private func handleZoomSettingChange() {
        // Zoom setting changed (e.g., from Settings) — update camera immediately
        if trackingMode != .free, let location = stateMachine.currentLocation {
            updateCamera(for: location)
        }
    }

    private func updateCameraForHeadingChange(location: CLLocation, heading: Double) {
        guard isVisible else { return }
        let camera: MapCamera
        switch trackingMode {
        case .followWithHeading:
            camera = MapCamera(
                centerCoordinate: location.coordinate,
                distance: zoomLevel.distance,
                heading: heading,
                pitch: 0
            )
        case .drivingView:
            let speedMPH = stateMachine.currentSpeedMPH
            let lookAheadMeters: Double = speedMPH >= 5 ? 120 : 60
            let centerAhead = location.coordinate.projected(distance: lookAheadMeters, bearing: heading)
            let pitch: Double = speedMPH >= 5 ? 60 : 10
            camera = MapCamera(
                centerCoordinate: centerAhead,
                distance: zoomLevel.drivingDistance,
                heading: heading,
                pitch: pitch
            )
        case .free, .follow:
            return
        }

        withAnimation(.linear(duration: 0.14)) {
            cameraPosition = .camera(camera)
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
        guard isVisible else { return }
        let heading = refreshResolvedHeading(for: location)
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
        guard isVisible else { return }
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
        case .follow: return "location.fill"
        case .followWithHeading: return "location.north.line.fill"
        case .drivingView: return "location.north.circle.fill"
        }
    }
    
    private var trackingModeColor: Color {
        switch trackingMode {
        case .free: return .secondary
        case .follow: return .blue
        case .followWithHeading: return .cyan
        case .drivingView: return .mint
        }
    }
    
    private func handleLocationButtonTap() {
        let isDrivingLikeState = stateMachine.state == .driving || stateMachine.state == .maybeDriving

        withAnimation {
            switch trackingMode {
            case .free:
                // From free → follow (center on user)
                trackingMode = .follow
            case .follow:
                // From follow → heading (rotate map with direction)
                trackingMode = .followWithHeading
            case .followWithHeading:
                if isDrivingLikeState {
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
        }

        primeHeadingConeIfNeeded()

        if let location = stateMachine.currentLocation {
            updateCamera(for: location)
        } else {
            // State still cycles even if we don't have a fresh fix yet.
            // Request a one-shot update so the next sample recenters/rotates as expected.
            Task { @MainActor in
                locationManager.requestOneShotLocation(reason: "locationButton")
            }
        }
    }

    private func primeHeadingConeIfNeeded() {
        guard trackingMode == .followWithHeading || trackingMode == .drivingView else { return }
        if let location = stateMachine.currentLocation {
            _ = refreshResolvedHeading(for: location)
            return
        }
        if let compassHeading = currentDeviceHeading() {
            liveResolvedHeading = compassHeading
            return
        }
        liveResolvedHeading = normalizeHeading(mapHeading)
    }

    private func resolvedHeading(for location: CLLocation) -> Double {
        enum HeadingSource {
            case course
            case compass
        }

        let speedMPH = max(0, location.speed * 2.23694)
        let courseHeading = location.course >= 0 ? normalizeHeading(location.course) : nil
        let compassHeading = currentDeviceHeading()

        let target: (heading: Double, source: HeadingSource)?
        if speedMPH >= minSpeedForHeadingMPH, let courseHeading {
            target = (courseHeading, .course)
        } else if let compassHeading {
            target = (compassHeading, .compass)
        } else if let courseHeading {
            target = (courseHeading, .course)
        } else {
            target = nil
        }

        guard let target else {
            return hasCourseHeading ? lastCourseHeading : 0
        }

        if !hasCourseHeading {
            lastCourseHeading = target.heading
            hasCourseHeading = true
        } else {
            let delta = shortestAngleDelta(from: lastCourseHeading, to: target.heading)
            let alpha = target.source == .course ? headingSmoothingAlphaCourse : headingSmoothingAlphaCompass
            lastCourseHeading = normalizeHeading(lastCourseHeading + alpha * delta)
        }

        return lastCourseHeading
    }

    @discardableResult
    private func refreshResolvedHeading(for location: CLLocation) -> Double {
        let heading = resolvedHeading(for: location)
        liveResolvedHeading = heading
        return heading
    }

    private func currentDeviceHeading() -> Double? {
        guard let heading = locationManager.currentHeading else { return nil }
        guard heading.headingAccuracy >= 0 else { return nil }
        // Be permissive so the cone remains visible while calibration settles.
        guard heading.headingAccuracy <= 120 else { return nil }

        if heading.trueHeading >= 0 {
            return normalizeHeading(heading.trueHeading)
        }
        if heading.magneticHeading >= 0 {
            return normalizeHeading(heading.magneticHeading)
        }
        return nil
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
        guard let center = mapCenterCoordinate ?? stateMachine.currentLocation?.coordinate else { return }

        withAnimation(.easeInOut(duration: 0.3)) {
            cameraPosition = .camera(MapCamera(
                centerCoordinate: center,
                distance: max(cameraDistance, 120),
                heading: 0,
                pitch: mapPitch
            ))
        }
    }
    
    // MARK: - New Helper Function Added
    
    private func centerDistanceMeters(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> CLLocationDistance {
        let la = CLLocation(latitude: a.latitude, longitude: a.longitude)
        let lb = CLLocation(latitude: b.latitude, longitude: b.longitude)
        return la.distance(from: lb)
    }
    
    // MARK: - History Cache Helper
    
    private func updateHistoryCache() {
        // Run as a task on MainActor (since accessing SwiftData models)
        // But yield to allow UI responsiveness
        Task { @MainActor in
            guard let windowStart = historyTimeSpan.windowStart else {
                withAnimation {
                    historyRouteCache = [:]
                }
                selectedHistoryRoute = nil
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
            
            if let selected = selectedHistoryRoute, newCache[selected.id] == nil {
                selectedHistoryRoute = nil
            }
        }
    }

    private func historyRouteColor(hue: Double, opacity: Double) -> Color {
        Color(hue: hue, saturation: 0.8, brightness: 0.92).opacity(opacity)
    }

    private func historyRouteHue(for index: Int, total: Int) -> Double {
        // Golden-step palette keeps neighboring routes visually distinct.
        let goldenStep = 0.61803398875
        let base = (Double(index) * goldenStep).truncatingRemainder(dividingBy: 1.0)
        
        // Small spread term helps avoid accidental near-collisions in short route sets.
        guard total > 1 else { return base }
        let spread = (Double(index) / Double(total - 1)) * 0.08
        return (base + spread).truncatingRemainder(dividingBy: 1.0)
    }
    
    private func historyRouteOpacity(for endTime: Date) -> Double {
        // Re-introduce subtle recency layering without making old routes hard to see.
        guard let windowStart = historyTimeSpan.windowStart else { return 0.74 }
        let now = Date()
        let windowDuration = max(now.timeIntervalSince(windowStart), 1)
        let age = max(0, now.timeIntervalSince(endTime))
        let normalizedAge = min(1, age / windowDuration)
        
        // Newest ≈ 0.84, oldest ≈ 0.62
        return 0.84 - (normalizedAge * 0.22)
    }

    // MARK: - History Route Selection

    private func handleHistoryRouteTap(at coordinate: CLLocationCoordinate2D) {
        guard canSelectHistoryRoutes else { return }
        let thresholdMeters = routeSelectionThresholdMeters
        guard let selectedId = nearestHistoryRoute(to: coordinate, thresholdMeters: thresholdMeters) else {
            cancelRouteFocusTask()
            selectedHistoryRoute = nil
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                bottomBarDetent = .peek
            }
            return
        }
        guard let selection = buildHistorySelection(for: selectedId) else {
            cancelRouteFocusTask()
            selectedHistoryRoute = nil
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                bottomBarDetent = .peek
            }
            return
        }

        // Same-route retap: re-fit immediately with a short animation.
        if selectedHistoryRoute?.id == selectedId || lastFocusedRouteId == selectedId {
            cancelRouteFocusTask()
            trackingMode = .free
            selectedHistoryRoute = selection
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                bottomBarDetent = .medium
            }
            focusCamera(
                on: selectedId,
                detent: .medium,
                animated: true,
                duration: routeRefitAnimationDuration
            )
            return
        }

        cancelRouteFocusTask()
        trackingMode = .free
        selectedHistoryRoute = selection
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            bottomBarDetent = .medium
        }
        routeFocusTask = Task { @MainActor in
            defer { routeFocusTask = nil }
            try? await Task.sleep(nanoseconds: routeFocusSheetFirstDelayMs * 1_000_000)
            guard !Task.isCancelled else { return }
            guard selectedHistoryRoute?.id == selectedId else { return }
            focusCamera(
                on: selectedId,
                detent: .medium,
                animated: true,
                duration: routeFocusAnimationDuration
            )
        }
    }

    private func cancelRouteFocusTask() {
        routeFocusTask?.cancel()
        routeFocusTask = nil
    }

    private func routeOcclusionBias(for detent: BottomBarDetent) -> Double {
        switch detent {
        case .peek: return 0.10
        case .medium: return 0.22
        case .full: return 0.32
        }
    }

    private func clampLatitude(_ value: Double) -> Double {
        min(max(value, -85.0), 85.0)
    }

    private func clampLongitude(_ value: Double) -> Double {
        min(max(value, -180.0), 180.0)
    }

    private func routeRegion(for route: HistoryRoute, detent: BottomBarDetent) -> MKCoordinateRegion? {
        let coords = route.coordinates
        guard !coords.isEmpty else { return nil }

        // Fallback for tiny routes: keep zoom stable around the point.
        if coords.count < 2, let first = coords.first {
            let span = MKCoordinateSpan(
                latitudeDelta: routeFocusMinSpanDelta,
                longitudeDelta: routeFocusMinSpanDelta
            )
            let lat = clampLatitude(first.latitude)
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: lat, longitude: first.longitude),
                span: span
            )
        }

        let lats = coords.map(\.latitude)
        let lons = coords.map(\.longitude)
        guard let minLat = lats.min(),
              let maxLat = lats.max(),
              let minLon = lons.min(),
              let maxLon = lons.max() else {
            return nil
        }

        let latDeltaRaw = (maxLat - minLat) * routeFocusPaddingFactor
        let lonDeltaRaw = (maxLon - minLon) * routeFocusPaddingFactor
        let latDelta = max(latDeltaRaw, routeFocusMinSpanDelta)
        let lonDelta = max(lonDeltaRaw, routeFocusMinSpanDelta)
        let span = MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)

        let occlusionBias = routeOcclusionBias(for: detent)
        let centerLatRaw = ((minLat + maxLat) / 2) - (latDelta * occlusionBias * 0.55)
        let centerLat = clampLatitude(centerLatRaw)
        let centerLon = clampLongitude((minLon + maxLon) / 2)
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
            span: span
        )
    }

    private func focusCamera(on routeId: UUID, detent: BottomBarDetent, animated: Bool, duration: TimeInterval) {
        guard let route = historyRouteCache[routeId] else { return }
        guard let region = routeRegion(for: route, detent: detent) else { return }

        trackingMode = .free
        let applyCamera = {
            cameraPosition = .region(region)
        }

        if animated {
            withAnimation(.easeInOut(duration: duration)) {
                applyCamera()
            }
        } else {
            applyCamera()
        }
        lastFocusedRouteId = routeId
    }
    
    private func nearestHistoryRoute(
        to coordinate: CLLocationCoordinate2D,
        thresholdMeters: Double
    ) -> UUID? {
        let tapPoint = MKMapPoint(coordinate)
        let pointsPerMeter = MKMapPointsPerMeterAtLatitude(coordinate.latitude)
        let thresholdMapPoints = thresholdMeters * pointsPerMeter
        
        var bestId: UUID?
        var bestDistance = thresholdMeters
        
        for (driveId, route) in historyRouteCache {
            let coords = route.coordinates
            guard coords.count > 1 else { continue }
            
            let points = coords.map { MKMapPoint($0) }
            let rect = mapRect(for: points).insetBy(dx: -thresholdMapPoints, dy: -thresholdMapPoints)
            guard rect.contains(tapPoint) else { continue }
            
            let distance = distanceFrom(point: tapPoint, to: points)
            if distance < bestDistance {
                bestDistance = distance
                bestId = driveId
            }
        }
        
        return bestId
    }
    
    private func distanceFrom(point: MKMapPoint, to points: [MKMapPoint]) -> Double {
        guard points.count > 1 else { return .greatestFiniteMagnitude }
        var best = Double.greatestFiniteMagnitude
        
        for index in 0..<(points.count - 1) {
            let a = points[index]
            let b = points[index + 1]
            let distance = distanceFrom(point: point, toSegmentFrom: a, to: b)
            if distance < best {
                best = distance
            }
        }
        
        return best
    }
    
    private func distanceFrom(point: MKMapPoint, toSegmentFrom a: MKMapPoint, to b: MKMapPoint) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        
        if dx == 0 && dy == 0 {
            return point.distance(to: a)
        }
        
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / (dx * dx + dy * dy)))
        let projection = MKMapPoint(x: a.x + t * dx, y: a.y + t * dy)
        return point.distance(to: projection)
    }
    
    private func mapRect(for points: [MKMapPoint]) -> MKMapRect {
        var rect = MKMapRect.null
        for point in points {
            let pointRect = MKMapRect(origin: point, size: MKMapSize(width: 0, height: 0))
            rect = rect.union(pointRect)
        }
        return rect
    }
    
    private func buildHistorySelection(for driveId: UUID) -> HistoryRouteSelection? {
        guard let drive = allDrives.first(where: { $0.id == driveId }) else { return nil }
        let title = historyRouteTitle(for: drive)
        let timeRange = formattedTimeRange(for: drive)
        
        let counts = drive.accelerationEvents.reduce(into: [AccelerationEventType: Int]()) { result, event in
            result[event.eventType, default: 0] += 1
        }
        
        return HistoryRouteSelection(
            id: drive.id,
            title: title,
            timeRangeText: timeRange,
            distanceMiles: drive.distanceMiles,
            duration: drive.duration,
            avgSpeedMPH: drive.averageSpeedMPH,
            maxSpeedMPH: drive.maxSpeedMPH,
            gForceCounts: counts
        )
    }
    
    private func historyRouteTitle(for drive: Drive) -> String {
        if let endPlaceId = drive.endPlaceId,
           let place = savedPlaces.first(where: { $0.placeId == endPlaceId }) {
            return "Drive to \(place.name)"
        }
        if let endNeighborhood = drive.endNeighborhood, !endNeighborhood.isEmpty {
            return "Drive to \(endNeighborhood)"
        }
        return "Drive Summary"
    }
    
    private func formattedTimeRange(for drive: Drive) -> String {
        let start = drive.startTime
        let end = drive.endTime ?? Date()
        
        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: start, to: end)
    }

    // MARK: - Compass Helpers

    private var compassCardinalLabel: String {
        // Nearest cardinal direction (N, E, S, W)
        let heading = normalizeHeading(mapHeading)
        let index = Int((heading + 45) / 90) % 4
        return ["N", "E", "S", "W"][index]
    }

    private var compassControl: some View {
        Button(action: resetToNorth) {
            ZStack {
                Circle()
                    .fill(.black.opacity(0.52))
                    .background(Circle().fill(.ultraThinMaterial))

                Circle()
                    .stroke(.white.opacity(0.18), lineWidth: 1)

                compassTickRing

                Text(compassCardinalLabel)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white.opacity(0.95))
                    .frame(width: 34, height: 18)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Image(systemName: "triangle.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.red)
                    .offset(y: -19)
                    .rotationEffect(.degrees(-normalizeHeading(mapHeading)))
                    .animation(.linear(duration: 0.12), value: mapHeading)
            }
            .frame(width: 56, height: 56)
            .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Compass")
        .accessibilityHint("Resets map to north up")
    }

    private var compassTickRing: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { index in
                let angle = Double(index) * 90
                let isNorth = index == 0
                let tickColor: Color = isNorth ? .red.opacity(0.95) : .white.opacity(0.84)

                Capsule(style: .continuous)
                    .fill(tickColor)
                    .frame(
                        width: isNorth ? 2.2 : 1.8,
                        height: isNorth ? 10 : 8
                    )
                    .offset(y: -22)
                    .rotationEffect(.degrees(angle))
            }
        }
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

private struct MapStylePickerSheet: View {
    let selectedStyle: DashboardView.MapVisualStyle
    let onSelect: (DashboardView.MapVisualStyle) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Map Type")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.bold))
                        .padding(10)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            ForEach(DashboardView.MapVisualStyle.allCases, id: \.self) { style in
                Button {
                    onSelect(style)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: icon(for: style))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.95))
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(iconColor(for: style))
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(style.title)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(style.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: selectedStyle == style ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(selectedStyle == style ? .blue : .secondary.opacity(0.35))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(selectedStyle == style ? Color.blue.opacity(0.12) : Color.white.opacity(0.04))
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
    }

    private func icon(for style: DashboardView.MapVisualStyle) -> String {
        switch style {
        case .standard: return "map"
        case .hybrid: return "square.3.layers.3d"
        case .satellite: return "globe.americas.fill"
        }
    }

    private func iconColor(for style: DashboardView.MapVisualStyle) -> Color {
        switch style {
        case .standard: return .blue
        case .hybrid: return .teal
        case .satellite: return .indigo
        }
    }
}

private struct HeadingConeOverlay: View {
    let heading: Double
    let mapHeading: Double
    let speedMPS: Double
    let coneScale: CGFloat

    private var opacity: Double {
        if speedMPS < 0.4 { return 0.70 }
        if speedMPS < 2.0 { return 0.76 }
        return 0.82
    }

    private var effectiveRotation: Double {
        var angle = heading - mapHeading
        while angle < 0 { angle += 360 }
        while angle >= 360 { angle -= 360 }
        return angle
    }

    var body: some View {
        HeadingConeView()
            .scaleEffect(coneScale)
            .offset(x: 26 * coneScale, y: 0)
            .rotationEffect(.degrees(effectiveRotation - 90))
            .opacity(opacity)
    }
}

private struct PuckWithHeadingOverlay: View {
    let showCone: Bool
    let heading: Double?
    let mapHeading: Double
    let speedMPS: Double
    let coneScale: CGFloat

    var body: some View {
        ZStack {
            HeadingConeOverlay(
                heading: heading ?? mapHeading,
                mapHeading: mapHeading,
                speedMPS: speedMPS,
                coneScale: coneScale
            )
            .opacity(showCone ? 1 : 0)

            Circle()
                .fill(Color.blue.opacity(0.92))
                .frame(width: 14, height: 14)

            Circle()
                .stroke(Color.white.opacity(0.95), lineWidth: 3)
                .frame(width: 18, height: 18)
        }
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
        ZStack {
            // Subtle glow halo to keep the cone visible over dark map tiles.
            HeadingConeShape()
                .fill(Color.cyan.opacity(0.28))
                .scaleEffect(x: 1.08, y: 1.16, anchor: .leading)
                .blur(radius: 7)

            HeadingConeShape()
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: Color.blue.opacity(0.92), location: 0.0),
                            .init(color: Color.cyan.opacity(0.58), location: 0.40),
                            .init(color: Color.cyan.opacity(0.26), location: 0.74),
                            .init(color: Color.clear, location: 1.0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            
            HeadingConeShape()
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.24), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: 1
                )

            // Soft secondary pass to keep the tail readable when stationary.
            HeadingConeShape()
                .fill(Color.blue.opacity(0.18))
                .blur(radius: 2.4)
        }
        .frame(width: 64, height: 48)
        .compositingGroup()
    }
}

struct HeadingConeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Slightly widened nose near the puck for better readability.
        let noseTop = CGPoint(x: rect.minX + rect.width * 0.02, y: rect.midY - rect.height * 0.08)
        let noseBottom = CGPoint(x: rect.minX + rect.width * 0.02, y: rect.midY + rect.height * 0.08)
        let topRight = CGPoint(x: rect.maxX, y: rect.minY)
        let bottomRight = CGPoint(x: rect.maxX, y: rect.maxY)
        
        path.move(to: noseTop)
        path.addLine(to: topRight)
        path.addLine(to: bottomRight)
        path.addLine(to: noseBottom)
        path.closeSubpath()
        
        return path
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
        locationManager: LocationManager(),
        selectedHistoryRoute: .constant(nil),
        bottomBarDetent: .constant(.peek),
        isVisible: true
    )
}
