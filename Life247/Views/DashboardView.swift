//
//  DashboardView.swift
//  Life247
//
//  Created by Andrew Robertson on 1/14/26.
//

import SwiftUI
import MapKit
import SwiftData
import Combine

/// Main dashboard displaying the live map.
/// Uses MapCameraPolicy for camera behavior.
struct DashboardView: View {
    @Bindable var stateMachine: DriveStateMachine
    @ObservedObject var locationManager: LocationManager
    @Binding var selectedHistoryRoute: HistoryRouteSelection?
    @Binding var bottomBarDetent: BottomBarDetent
    @Environment(\.modelContext) private var modelContext
    @Query private var savedPlaces: [Place]
    @StateObject private var viewModel = DashboardViewModel()
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
    @State private var liveResolvedHeading: Double?
    @State private var puckRenderNonce: Int = 0
    @AppStorage("historyTimeSpan") private var historyTimeSpanRaw: String = HistoryTimeSpan.off.rawValue
    @State private var routeCoordinates: [CLLocationCoordinate2D] = []  // Cached for stable polyline
    @State private var lastSyncedRouteDriveId: UUID?
    @State private var lastSyncedRoutePointCount: Int = 0
    @State private var lastSyncedRouteTimestamp: Date?
    @State private var uniqueMapPlacesCache: [Place] = []
    @State private var showMapStyleSheet = false
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
    private let headingSmoothingAlphaCourse: Double = 0.25
    private let headingSmoothingAlphaCompass: Double = 0.45
    private let headingUpdateThresholdDegrees: Double = 1.5
    private let minHeadingUpdateInterval: TimeInterval = 0.08
    private let routeFocusSheetFirstDelayMs: UInt64 = 140
    private let routeFocusAnimationDuration: TimeInterval = 0.42
    private let routeRefitAnimationDuration: TimeInterval = 0.25
    private let routeFocusMinSpanDelta: Double = 0.004
    private let routeFocusPaddingFactor: Double = 1.22
    private let activeRouteLineWidth: CGFloat = 6
    private let routeSyncIntervalNanoseconds: UInt64 = 8_000_000_000
    private let liveTailMinDistanceMeters: Double = 2
    private let liveTailMaxDistanceMeters: Double = 1200
    private let routeWatchdogLagPointThreshold: Int = 4
    private let routeWatchdogMinLagDurationSeconds: TimeInterval = 4
    private let routeWatchdogRecoveryCooldownSeconds: TimeInterval = 8
    private let freeModeAutoRecenterGraceSeconds: TimeInterval = 6
    private let freeModeAutoRecenterMinDistanceMeters: Double = 35
    private let freeModeAutoRecenterMaxDistanceMeters: Double = 90
    private let maxHistoryOverlayPointsPerRoute: Int = 800
    private let maxHistoryHitTestPointsPerRoute: Int = 2400
    private let historyRouteDimmedOpacityMultiplier: Double = 0.42
    private let tapCycleMaxInterval: TimeInterval = 2.0
    private let tapCycleAnchorMinDistanceMeters: Double = 18.0

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
        let strokeOpacity: Double
        let strokeWidth: CGFloat
    }

    private var placeCircleStyle: PlaceCircleStyle {
        // Filled + bordered rendering matches Apple/Google Maps geofence conventions.
        switch cameraDistance {
        case ..<1200:
            return PlaceCircleStyle(fillOpacity: 0.14, strokeOpacity: 0.55, strokeWidth: 2.0)
        case ..<5000:
            return PlaceCircleStyle(fillOpacity: 0.10, strokeOpacity: 0.45, strokeWidth: 1.5)
        case ..<18000:
            return PlaceCircleStyle(fillOpacity: 0.08, strokeOpacity: 0.35, strokeWidth: 1.2)
        default:
            return PlaceCircleStyle(fillOpacity: 0.05, strokeOpacity: 0.25, strokeWidth: 1.0)
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

    private func isDrivingLike(_ state: DriveState) -> Bool {
        state == .driving || state == .maybeDriving
    }

    private func isRouteSyncState(_ state: DriveState) -> Bool {
        isDrivingLike(state) || state == .stopped || state == .pendingArrival
    }

    private func isLiveTailState(_ state: DriveState) -> Bool {
        state == .driving || state == .stopped || state == .pendingArrival
    }

    private var cameraRuntime: DashboardCameraRuntime {
        viewModel.cameraRuntime
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
        let scaled = cameraDistance * 0.03
        return min(120, max(25, scaled))
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

    private var shouldShowDwellBubble: Bool {
        cameraDistance < 6000
    }

    private var dwellBubbleYOffset: CGFloat {
        switch cameraDistance {
        case ..<1200: return -24
        case ..<3500: return -20
        default: return -16
        }
    }

    private var activeDwellDotSize: CGFloat {
        switch cameraDistance {
        case ..<2000: return 9
        case ..<7000: return 8
        default: return 6.5
        }
    }

    private var activeDwellRingSize: CGFloat {
        switch cameraDistance {
        case ..<2000: return 16
        case ..<7000: return 13
        default: return 10
        }
    }
    
    // Camera updates are driven directly by stateMachine.currentLocation.
    // Puck/cone rendering uses a custom annotation to keep icon + cone in sync.
    
    /// The place where active dwell is happening.
    /// Uses name+proximity first to heal duplicate-place drift, then placeId fallback.
    private var activeDwellPlace: Place? {
        let places = uniqueMapPlaces
        if let dwell = stateMachine.activeDwellSummary {
            if let current = stateMachine.currentLocation {
                let accuracyBuffer = min(40.0, max(10.0, current.horizontalAccuracy))
                let containingNameMatches = places.filter {
                    $0.name == dwell.placeName &&
                    $0.contains(current.coordinate, additionalBufferMeters: accuracyBuffer)
                }
                if !containingNameMatches.isEmpty {
                    return containingNameMatches.min { lhs, rhs in
                        if abs(lhs.effectiveRadius - rhs.effectiveRadius) > 0.5 {
                            return lhs.effectiveRadius < rhs.effectiveRadius
                        }
                        return lhs.distance(to: current.coordinate) < rhs.distance(to: current.coordinate)
                    }
                }
            }

            let proximityThreshold = max(25.0, min(dwell.placeRadiusMeters * 0.6, 90.0))
            // Heal stale visits linked to older duplicate records by preferring
            // nearby same-name places with the tightest radius.
            let nearbyNameMatches = places.filter {
                $0.name == dwell.placeName && $0.distance(to: dwell.placeCoordinate) <= proximityThreshold
            }
            if !nearbyNameMatches.isEmpty {
                return nearbyNameMatches.min { lhs, rhs in
                    if abs(lhs.effectiveRadius - rhs.effectiveRadius) > 0.5 {
                        return lhs.effectiveRadius < rhs.effectiveRadius
                    }
                    return lhs.distance(to: dwell.placeCoordinate) < rhs.distance(to: dwell.placeCoordinate)
                }
            }

            if let dwellPlaceId = dwell.placeId,
               let matched = places.first(where: { $0.placeId == dwellPlaceId }) {
                return matched
            }

            let nameMatches = places.filter { $0.name == dwell.placeName }
            if !nameMatches.isEmpty {
                return nameMatches.min { lhs, rhs in
                    lhs.distance(to: dwell.placeCoordinate) < rhs.distance(to: dwell.placeCoordinate)
                }
            }
            return places.min { lhs, rhs in
                lhs.distance(to: dwell.placeCoordinate) < rhs.distance(to: dwell.placeCoordinate)
            }
        }

        if let soft = softDwell {
            if let matched = places.first(where: { $0.placeId == soft.placeId }) {
                return matched
            }

            let candidates = places.filter { $0.name == soft.placeName }
            if let coordinate = stateMachine.currentLocation?.coordinate, !candidates.isEmpty {
                return candidates.min { lhs, rhs in
                    lhs.distance(to: coordinate) < rhs.distance(to: coordinate)
                }
            }
            return candidates.first
        }

        return nil
    }

    /// Places used for map rendering (deduplicated by spatial + semantic signature).
    /// This prevents stacked duplicate circles from becoming an opaque white disk.
    private var uniqueMapPlaces: [Place] {
        uniqueMapPlacesCache
    }

    private func canonicalMapPlace(from cluster: [Place]) -> Place? {
        guard !cluster.isEmpty else { return nil }
        let count = Double(cluster.count)
        let centroid = CLLocationCoordinate2D(
            latitude: cluster.reduce(0.0) { $0 + $1.latitude } / count,
            longitude: cluster.reduce(0.0) { $0 + $1.longitude } / count
        )
        return cluster.min { lhs, rhs in
            if abs(lhs.effectiveRadius - rhs.effectiveRadius) > 0.5 {
                return lhs.effectiveRadius < rhs.effectiveRadius
            }
            let lhsDistance = lhs.distance(to: centroid)
            let rhsDistance = rhs.distance(to: centroid)
            if abs(lhsDistance - rhsDistance) > 0.5 {
                return lhsDistance < rhsDistance
            }
            return lhs.placeId.uuidString < rhs.placeId.uuidString
        }
    }

    private func normalizePlaceName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var savedPlacesSignature: String {
        let parts = savedPlaces.map { place in
            "\(place.placeId.uuidString)|\(place.latitude)|\(place.longitude)|\(place.clampedRadiusMeters)|\(normalizePlaceName(place.name))"
        }
        return parts.sorted().joined(separator: ";")
    }

    private func updateUniqueMapPlacesCache() {
        uniqueMapPlacesCache = computeUniqueMapPlaces(from: savedPlaces)
    }

    private func computeUniqueMapPlaces(from places: [Place]) -> [Place] {
        guard !places.isEmpty else { return [] }
        let proximityThresholdMeters: CLLocationDistance = 35
        let grouped = Dictionary(grouping: places) { normalizePlaceName($0.name) }
        var deduped: [Place] = []

        for (_, sameNamePlaces) in grouped {
            var clusters: [[Place]] = []

            for place in sameNamePlaces {
                if let clusterIndex = clusters.firstIndex(where: { cluster in
                    cluster.contains { candidate in
                        candidate.distance(to: place.coordinate) <= proximityThresholdMeters
                    }
                }) {
                    clusters[clusterIndex].append(place)
                } else {
                    clusters.append([place])
                }
            }

            for cluster in clusters {
                guard let canonical = canonicalMapPlace(from: cluster) else { continue }
                deduped.append(canonical)
            }
        }

        return deduped.sorted {
            if $0.name != $1.name { return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            if $0.latitude != $1.latitude { return $0.latitude < $1.latitude }
            return $0.longitude < $1.longitude
        }
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
                guard viewModel.routeFocusTask == nil else { return }
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
                    viewModel.lastFocusedRouteId = nil
                    viewModel.historyTapCycleState = nil
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
            .onDisappear {
                cancelHistoryCacheTask()
                cancelRouteFocusTask()
                viewModel.historyTapCycleState = nil
                stopRouteSyncTask()
                resetRouteWatchdogState()
            }
            .onChange(of: isVisible) { _, visible in
                if visible {
                    puckRenderNonce &+= 1
                    if isHeadingTrackingMode {
                        primeHeadingConeIfNeeded()
                    }
                    syncActiveRoutePoints(force: true)
                    updateHistoryCache()
                    startRouteSyncTaskIfNeeded()
                } else {
                    cancelHistoryCacheTask()
                    cancelRouteFocusTask()
                    viewModel.historyTapCycleState = nil
                    stopRouteSyncTask()
                    resetRouteWatchdogState()
                }
            }
            // Use .task for route initialization - runs before first render, guaranteed
            .task { if isVisible { initializeRouteCacheFromActiveDrive() } }
            .onChange(of: stateMachine.currentLocation) { _, newLocation in
                guard isVisible else { return }
                // Route sync is driven by routePointVersion updates.
                // A periodic task + watchdog remain as safety nets.
                handleLocationChange(newLocation)
            }
            .onChange(of: savedPlacesSignature) { _, _ in
                updateUniqueMapPlacesCache()
            }
            .onChange(of: stateMachine.routePointVersion) { _, _ in
                guard isVisible else { return }
                syncActiveRoutePoints()
            }
            .onChange(of: stateMachine.activeDrive?.id) { _, _ in
                syncActiveRoutePoints(force: true)
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
            .onChange(of: defaultZoomLevelRaw) { _, _ in
                guard isVisible else { return }
                handleZoomSettingChange()
            }
            // Update history cache when history span changes.
            .onChange(of: historyTimeSpan) { _, _ in
                if isVisible {
                    updateHistoryCache()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .driveEnded)) { _ in
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
                let disengageThreshold: CGFloat = isDrivingLike(stateMachine.state) ? 48 : 22
                guard translation > disengageThreshold else { return }
                if trackingMode != .free {
                    let previousMode = trackingMode
                    trackingMode = .free
                    logMapTrackingEvent(
                        type: "map_follow_disengaged_pan",
                        message: "Map follow disengaged by pan",
                        metadata: [
                            "fromMode": trackingModeLabel(previousMode),
                            "threshold": String(format: "%.0f", disengageThreshold)
                        ]
                    )
                }
                cameraRuntime.lastManualTrackingDisengageAt = Date()
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
        // Draw route beneath puck so the vehicle marker/cone is always top-most.
        routeContent
        puckContent
    }
    
    /// Places layer - circles and annotations
    @MapContentBuilder
    private var placesContent: some MapContent {
        if shouldShowPlaces {
            ForEach(uniqueMapPlaces) { place in
                placeCircle(for: place)
            }
            if showPlaceCenterMarkers {
                ForEach(uniqueMapPlaces) { place in
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
    /// Uses MapCircle with soft fill + clean border (Apple/Google Maps convention).
    @MapContentBuilder
    private func placeCircle(for place: Place) -> some MapContent {
        let style = placeCircleStyle
        let color = placeColor(for: place.icon)
        let displayRadius = place.clampedRadiusMeters
        let isActivePlace = activeDwellPlace?.id == place.id

        // Soft fill
        MapCircle(center: place.coordinate, radius: displayRadius)
            .foregroundStyle(color.opacity(isActivePlace ? style.fillOpacity * 1.6 : style.fillOpacity))
        // Clean border
        MapCircle(center: place.coordinate, radius: displayRadius)
            .foregroundStyle(.clear)
            .stroke(color.opacity(isActivePlace ? style.strokeOpacity * 1.3 : style.strokeOpacity), lineWidth: style.strokeWidth)
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
        if !isDriveInteractionLocked, historyTimeSpan != .off, !historyRouteCache.isEmpty {
            let selectedId = selectedHistoryRoute?.id
            let sortedRoutes = historyRouteCache.sorted { $0.value.endTime < $1.value.endTime }
            let indexedRoutes = Array(sortedRoutes.enumerated())
            
            ForEach(indexedRoutes, id: \.element.key) { indexedRoute in
                let driveId = indexedRoute.element.key
                let route = indexedRoute.element.value
                if driveId != selectedId {
                    let hue = historyRouteHue(for: indexedRoute.offset, total: sortedRoutes.count)
                    let baseOpacity = historyRouteOpacity(for: route.endTime)
                    let opacity = selectedId == nil
                        ? baseOpacity
                        : max(0.10, baseOpacity * historyRouteDimmedOpacityMultiplier)
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
            let coneCoordinate = livePuckCoordinate
            let showCone = isHeadingTrackingMode
            let speedMPS = max(0, stateMachine.currentLocation?.speed ?? 0)
            if let coordinate = coneCoordinate {
                // In heading modes, pin cone to displayed map heading to avoid left/right wobble
                // caused by camera-rotation lag vs. raw course updates.
                let headingValue: Double = showCone
                    ? normalizeHeading(mapHeading)
                    : (liveResolvedHeading ?? normalizeHeading(mapHeading))
                let annotationKey = "puck-\(showCone ? "heading" : "follow")-\(puckRenderNonce)"
                if showCone {
                    Annotation(annotationKey, coordinate: coordinate, anchor: .center) {
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
                    Annotation(annotationKey, coordinate: coordinate, anchor: .center) {
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
    /// Renders MapPolyline directly without identity wrappers (ForEach/nonce).
    /// SwiftUI Map updates the overlay in-place when routeCoordinates changes via @State.
    /// Using ForEach([nonce]) caused overlay destroy-recreate cycles that made the
    /// polyline silently disappear on MKMapView during the transition window.
    @MapContentBuilder
    private var routeContent: some MapContent {
        if routeCoordinates.count > 1 {
            MapPolyline(coordinates: routeCoordinates)
                .stroke(.blue, lineWidth: activeRouteLineWidth)
        }

        if let liveTailCoordinates {
            // Bridge temporary gaps between accepted route points and live puck position.
            // This prevents apparent "route cutoff" when persistence/filters lag briefly.
            MapPolyline(coordinates: liveTailCoordinates)
                .stroke(.blue, lineWidth: activeRouteLineWidth)
        }
    }

    private var liveTailCoordinates: [CLLocationCoordinate2D]? {
        guard isLiveTailState(stateMachine.state) else { return nil }
        guard let routeTail = routeCoordinates.last else { return nil }
        guard let live = livePuckCoordinate else { return nil }

        let distance = centerDistanceMeters(from: routeTail, to: live)
        guard distance >= liveTailMinDistanceMeters else { return nil }
        guard distance <= liveTailMaxDistanceMeters else { return nil }

        return [routeTail, live]
    }

    /// Shared live coordinate source used by both puck and live-tail rendering.
    /// Intentionally uses raw GPS cadence to avoid display-link frequency map-content churn.
    private var livePuckCoordinate: CLLocationCoordinate2D? {
        stateMachine.currentLocation?.coordinate
    }
    
    /// Minimal active-place marker used only to anchor dwell bubble (no place icon).
    private func activeDwellAnnotation(for place: Place) -> some MapContent {
        return Annotation(place.name, coordinate: place.coordinate, anchor: .bottom) {
            Button {
                selectedPlaceForDwell = place
            } label: {
                Circle()
                    .fill(.white.opacity(0.95))
                    .frame(width: activeDwellDotSize, height: activeDwellDotSize)
                    .overlay(
                        Circle()
                            .stroke(.white.opacity(0.5), lineWidth: 1)
                            .frame(width: activeDwellRingSize, height: activeDwellRingSize)
                    )
            }
            .buttonStyle(.plain)
            .overlay(alignment: .top) {
                if shouldShowDwellBubble {
                    dwellBubble
                        .fixedSize()  // Prevent clipping to parent size
                        .offset(y: dwellBubbleYOffset)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
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
                if isDrivingLike(stateMachine.state) {
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
        updateUniqueMapPlacesCache()
        syncActiveRoutePoints(force: true)
        startRouteSyncTaskIfNeeded()
        if let location = stateMachine.currentLocation {
            let age = Date().timeIntervalSince(location.timestamp)
            // Only use fresh locations for initial camera (avoid stale home cache)
            if age <= 12.0 {
                updateCamera(for: location)
            }
        }
        
        // Force drivingView if we recovered into an active driving state
        if isDrivingLike(stateMachine.state) {
            trackingMode = .drivingView
        }
    }

    private func initializeRouteCacheFromActiveDrive() {
        syncActiveRoutePoints(force: true)
    }

    private func handleLocationChange(_ newLocation: CLLocation?) {
        guard let location = newLocation else { return }

        let heading = refreshResolvedHeading(for: location)
        
        // Update camera directly from GPS location (no interpolator needed)
        if trackingMode != .free {
            updateCameraFromLocation(location: location, heading: heading)
        } else {
            maybeAutoReengageTracking(location: location, heading: heading)
        }

        ensureRenderedRouteIsCurrent()

        // Route updates are primarily driven by routePointVersion events.
        // The periodic task/watchdog are safety nets if that signal is missed.
        // If route updates lag behind live tracking,
        // recover in-place without requiring a tab switch.
        startRouteSyncTaskIfNeeded()
        monitorRouteSyncHealth(currentLocation: location)

        updateSoftDwellIfNeeded(currentLocation: location)
    }

    private func handleHeadingChange(_ newHeading: CLHeading?) {
        guard trackingMode == .followWithHeading || trackingMode == .drivingView else { return }
        guard newHeading != nil, let location = stateMachine.currentLocation else { return }

        let now = Date()
        guard now.timeIntervalSince(cameraRuntime.lastHeadingCameraUpdate) >= minHeadingUpdateInterval else { return }

        let heading = refreshResolvedHeading(for: location)
        let delta = abs(shortestAngleDelta(from: mapHeading, to: heading))
        guard delta >= headingUpdateThresholdDegrees else { return }

        cameraRuntime.lastHeadingCameraUpdate = now
        updateCameraForHeadingChange(location: location, heading: heading)
    }

    private func syncActiveRoutePoints(force: Bool = false) {
        guard let drive = stateMachine.activeDrive else {
            if !routeCoordinates.isEmpty || lastSyncedRouteDriveId != nil {
                applyRouteCoordinates([])
                lastSyncedRouteDriveId = nil
                lastSyncedRoutePointCount = 0
                lastSyncedRouteTimestamp = nil
            }
            return
        }

        let liveCoordinates = stateMachine.activeRouteCoordinates
        if !liveCoordinates.isEmpty {
            let driveChanged = lastSyncedRouteDriveId != drive.id
            if driveChanged {
                applyRouteCoordinates(liveCoordinates)
            } else if liveCoordinates.count >= routeCoordinates.count {
                applyRouteCoordinates(liveCoordinates)
            }

            lastSyncedRouteDriveId = drive.id
            lastSyncedRoutePointCount = max(lastSyncedRoutePointCount, routeCoordinates.count)
            lastSyncedRouteTimestamp = drive.latestPointTimestamp ?? lastSyncedRouteTimestamp
            return
        }

        let pointCount = drive.points.count
        let latestTimestamp = drive.latestPointTimestamp
        let driveChanged = lastSyncedRouteDriveId != drive.id
        let countChanged = lastSyncedRoutePointCount != pointCount
        let tailChanged = lastSyncedRouteTimestamp != latestTimestamp

        guard force || driveChanged || countChanged || tailChanged else { return }

        let freshCoordinates = drive.pointsChronological.map { $0.coordinate }

        if driveChanged {
            applyRouteCoordinates(freshCoordinates)
        } else {
            // SwiftData relationship snapshots can occasionally regress temporarily.
            // Never shrink an active route from a smaller refresh; wait for a larger/fresher sample.
            if freshCoordinates.count < routeCoordinates.count {
                lastSyncedRouteDriveId = drive.id
                lastSyncedRoutePointCount = max(lastSyncedRoutePointCount, routeCoordinates.count)
                if let latestTimestamp {
                    if let last = lastSyncedRouteTimestamp {
                        lastSyncedRouteTimestamp = max(last, latestTimestamp)
                    } else {
                        lastSyncedRouteTimestamp = latestTimestamp
                    }
                }
                return
            }
            applyRouteCoordinates(freshCoordinates)
        }

        lastSyncedRouteDriveId = drive.id
        lastSyncedRoutePointCount = max(pointCount, routeCoordinates.count)
        lastSyncedRouteTimestamp = latestTimestamp
    }

    private func applyRouteCoordinates(_ newCoordinates: [CLLocationCoordinate2D]) {
        guard shouldReplaceRouteCoordinates(with: newCoordinates) else { return }
        routeCoordinates = newCoordinates
    }

    private func shouldReplaceRouteCoordinates(with newCoordinates: [CLLocationCoordinate2D]) -> Bool {
        if newCoordinates.count != routeCoordinates.count {
            return true
        }
        guard let oldFirst = routeCoordinates.first,
              let oldLast = routeCoordinates.last,
              let newFirst = newCoordinates.first,
              let newLast = newCoordinates.last else {
            return routeCoordinates.isEmpty != newCoordinates.isEmpty
        }

        let firstChanged = abs(oldFirst.latitude - newFirst.latitude) > 0.0000001 ||
            abs(oldFirst.longitude - newFirst.longitude) > 0.0000001
        let lastChanged = abs(oldLast.latitude - newLast.latitude) > 0.0000001 ||
            abs(oldLast.longitude - newLast.longitude) > 0.0000001
        return firstChanged || lastChanged
    }

    private func startRouteSyncTaskIfNeeded() {
        guard viewModel.routeSyncTask == nil else { return }
        guard isVisible else { return }
        guard isRouteSyncState(stateMachine.state) else { return }

        viewModel.routeSyncTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: routeSyncIntervalNanoseconds)
                await MainActor.run {
                    syncActiveRoutePoints(force: true)
                }
            }
        }
    }

    private func stopRouteSyncTask() {
        viewModel.routeSyncTask?.cancel()
        viewModel.routeSyncTask = nil
    }

    private func resetRouteWatchdogState() {
        viewModel.routeLagBeganAt = nil
    }

    private func monitorRouteSyncHealth(currentLocation: CLLocation) {
        guard isVisible, isRouteSyncState(stateMachine.state) else {
            resetRouteWatchdogState()
            return
        }

        let liveCount = stateMachine.activeRouteCoordinates.count
        let lag = liveCount - routeCoordinates.count

        guard lag > 0 else {
            resetRouteWatchdogState()
            return
        }

        if viewModel.routeLagBeganAt == nil {
            viewModel.routeLagBeganAt = Date()
        }

        guard let lagStart = viewModel.routeLagBeganAt else { return }
        let now = Date()
        let lagDuration = now.timeIntervalSince(lagStart)
        let cooldownElapsed = now.timeIntervalSince(viewModel.lastRouteWatchdogRecoveryAt)

        guard lag >= routeWatchdogLagPointThreshold,
              lagDuration >= routeWatchdogMinLagDurationSeconds,
              cooldownElapsed >= routeWatchdogRecoveryCooldownSeconds else {
            return
        }

        let staleSeconds = Int(lagDuration.rounded())
        syncActiveRoutePoints(force: true)
        viewModel.lastRouteWatchdogRecoveryAt = now
        resetRouteWatchdogState()
        logMapTrackingEvent(
            type: "map_route_watchdog_resync",
            message: "Route watchdog forced resync after lag",
            metadata: [
                "lagPoints": String(lag),
                "lagSeconds": String(staleSeconds)
            ]
        )
    }

    private func ensureRenderedRouteIsCurrent() {
        guard isRouteSyncState(stateMachine.state) else { return }
        let live = stateMachine.activeRouteCoordinates
        guard !live.isEmpty else { return }

        let countDiffers = live.count != routeCoordinates.count
        let tailDiffers: Bool
        if let liveTail = live.last, let renderedTail = routeCoordinates.last {
            tailDiffers = abs(liveTail.latitude - renderedTail.latitude) > 0.0000001 ||
                abs(liveTail.longitude - renderedTail.longitude) > 0.0000001
        } else {
            tailDiffers = routeCoordinates.last != nil
        }

        if countDiffers || tailDiffers {
            syncActiveRoutePoints()
        }
    }

    private func handleDriveStateChange(from _: DriveState, to newState: DriveState) {
        if isRouteSyncState(newState) {
            selectedHistoryRoute = nil
            startRouteSyncTaskIfNeeded()
        } else {
            stopRouteSyncTask()
        }

        if isDrivingLike(newState) {
            // Auto-rotate map when driving (if user hasn't panned away)
            if trackingMode == .follow {
                let previousMode = trackingMode
                trackingMode = .followWithHeading
                logMapTrackingEvent(
                    type: "map_tracking_mode_auto",
                    message: "Auto-switched tracking mode on drive state change",
                    metadata: [
                        "fromMode": trackingModeLabel(previousMode),
                        "toMode": trackingModeLabel(trackingMode),
                        "state": newState.rawValue
                    ]
                )
                if let location = stateMachine.currentLocation {
                    updateCamera(for: location)
                }
            } else if trackingMode == .free {
                // Enter driving camera automatically when a drive begins from free mode.
                let previousMode = trackingMode
                trackingMode = .drivingView
                logMapTrackingEvent(
                    type: "map_tracking_mode_auto",
                    message: "Auto-switched tracking mode on drive state change",
                    metadata: [
                        "fromMode": trackingModeLabel(previousMode),
                        "toMode": trackingModeLabel(trackingMode),
                        "state": newState.rawValue
                    ]
                )
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
            guard let place = placeForSoftDwell(soft) else {
                softDwell = nil
                softDwellCandidate = nil
                return
            }

            let distance = place.distance(to: location.coordinate)
            let radius = place.effectiveRadius
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

        let radius = place.effectiveRadius
        let entryThreshold = max(0, radius - entryBufferMeters)
        guard distance <= entryThreshold else {
            softDwellCandidate = nil
            return
        }

        let key = softDwellKey(for: place)
        if softDwellCandidate?.key != key {
            softDwellCandidate = SoftDwellCandidate(
                key: key,
                placeId: place.placeId,
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
                placeId: candidate.placeId,
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
        guard let best = containing.min(by: { lhs, rhs in
            let lhsRadius = lhs.effectiveRadius
            let rhsRadius = rhs.effectiveRadius
            if abs(lhsRadius - rhsRadius) > 0.5 {
                return lhsRadius < rhsRadius
            }
            return lhs.distance(to: coordinate) < rhs.distance(to: coordinate)
        }) else {
            return nil
        }
        return (best, best.distance(to: coordinate))
    }

    private func placeForSoftDwellKey(_ key: String) -> Place? {
        savedPlaces.first { softDwellKey(for: $0) == key }
    }

    private func placeForSoftDwell(_ soft: SoftDwell) -> Place? {
        if let byId = savedPlaces.first(where: { $0.placeId == soft.placeId }) {
            return byId
        }
        return placeForSoftDwellKey(soft.key)
    }

    private func softDwellKey(for place: Place) -> String {
        "\(place.name)|\(place.latitude)|\(place.longitude)|\(place.clampedRadiusMeters)"
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
        
        cameraRuntime.lastCameraUpdate = Date()
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

    private func maybeAutoReengageTracking(location: CLLocation, heading: Double) {
        guard trackingMode == .free else { return }
        guard isDrivingLike(stateMachine.state) else { return }
        guard let mapCenterCoordinate else { return }

        if let disengagedAt = cameraRuntime.lastManualTrackingDisengageAt,
           Date().timeIntervalSince(disengagedAt) < freeModeAutoRecenterGraceSeconds {
            return
        }

        let driftMeters = centerDistanceMeters(from: mapCenterCoordinate, to: location.coordinate)
        let speedMPS = max(0, location.speed)
        let dynamicThreshold = min(
            freeModeAutoRecenterMaxDistanceMeters,
            max(freeModeAutoRecenterMinDistanceMeters, speedMPS * 5.0)
        )
        guard driftMeters >= dynamicThreshold else { return }

        let previousMode = trackingMode
        trackingMode = .drivingView
        cameraRuntime.lastManualTrackingDisengageAt = nil
        logMapTrackingEvent(
            type: "map_follow_auto_reengage",
            message: "Auto re-engaged map follow while driving",
            metadata: [
                "fromMode": trackingModeLabel(previousMode),
                "driftMeters": String(format: "%.1f", driftMeters),
                "thresholdMeters": String(format: "%.1f", dynamicThreshold)
            ]
        )
        updateCameraFromLocation(location: location, heading: heading)
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

    private func trackingModeLabel(_ mode: MapTrackingMode) -> String {
        switch mode {
        case .free: return "free"
        case .follow: return "follow"
        case .followWithHeading: return "followWithHeading"
        case .drivingView: return "drivingView"
        }
    }

    private func logMapTrackingEvent(
        type: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        guard isDrivingLike(stateMachine.state) else { return }
        stateMachine.logMapTrackingEvent(type: type, message: message, metadata: metadata)
    }
    
    private func handleLocationButtonTap() {
        let isDrivingLikeState = isDrivingLike(stateMachine.state)
        let previousMode = trackingMode

        withAnimation {
            switch trackingMode {
            case .free:
                // From free → follow (center on user)
                trackingMode = .follow
                cameraRuntime.lastManualTrackingDisengageAt = nil
            case .follow:
                // From follow → heading (rotate map with direction)
                trackingMode = .followWithHeading
                cameraRuntime.lastManualTrackingDisengageAt = nil
            case .followWithHeading:
                if isDrivingLikeState {
                    // From heading → cinematic driving view
                    trackingMode = .drivingView
                    cameraRuntime.lastManualTrackingDisengageAt = nil
                } else {
                    // From heading → back to free (exit tracking)
                    trackingMode = .free
                    cameraRuntime.lastManualTrackingDisengageAt = Date()
                }
            case .drivingView:
                // Keep tap-cycle in tracking modes while actively driving.
                // Free mode remains available via intentional map pan.
                if isDrivingLikeState {
                    trackingMode = .follow
                    cameraRuntime.lastManualTrackingDisengageAt = nil
                } else {
                    trackingMode = .free
                    cameraRuntime.lastManualTrackingDisengageAt = Date()
                }
            }
        }

        if trackingMode != previousMode {
            logMapTrackingEvent(
                type: "map_tracking_mode_button",
                message: "Tracking mode changed via location button",
                metadata: [
                    "fromMode": trackingModeLabel(previousMode),
                    "toMode": trackingModeLabel(trackingMode),
                    "drivingState": stateMachine.state.rawValue
                ]
            )
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
            return cameraRuntime.hasCourseHeading ? cameraRuntime.lastCourseHeading : 0
        }

        if !cameraRuntime.hasCourseHeading {
            cameraRuntime.lastCourseHeading = target.heading
            cameraRuntime.hasCourseHeading = true
        } else {
            let delta = shortestAngleDelta(from: cameraRuntime.lastCourseHeading, to: target.heading)
            let alpha = target.source == .course ? headingSmoothingAlphaCourse : headingSmoothingAlphaCompass
            cameraRuntime.lastCourseHeading = normalizeHeading(cameraRuntime.lastCourseHeading + alpha * delta)
        }

        return cameraRuntime.lastCourseHeading
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
        cancelHistoryCacheTask()
        // Run as one cancellable task to avoid overlapping heavy cache builds.
        viewModel.historyCacheTask = Task { @MainActor in
            defer { viewModel.historyCacheTask = nil }
            guard let windowStart = historyTimeSpan.windowStart else {
                historyRouteCache = [:]
                selectedHistoryRoute = nil
                viewModel.historyTapCycleState = nil
                return
            }
            
            let now = Date()
            guard let drivesToCache = fetchHistoryDrives(windowStart: windowStart, now: now) else {
                historyRouteCache = [:]
                selectedHistoryRoute = nil
                viewModel.historyTapCycleState = nil
                return
            }
            
            var newCache: [UUID: HistoryRoute] = [:]
            
            for drive in drivesToCache {
                guard !Task.isCancelled else { return }
                // Accessing pointsChronological triggers sorting on Main Thread
                // We yield every few drives to keep UI responsive
                let rawCoords = drive.pointsChronological.map { $0.coordinate }
                let coords = downsampleHistoryOverlayCoordinates(rawCoords)
                let hitTestCoords = downsampleHistoryHitTestCoordinates(rawCoords)
                let hitTestPoints = hitTestCoords.map(MKMapPoint.init)
                newCache[drive.id] = HistoryRoute(
                    coordinates: coords,
                    endTime: drive.endTime ?? drive.startTime,
                    hitTestPoints: hitTestPoints,
                    hitTestRect: mapRect(for: hitTestPoints)
                )
                await Task.yield()
            }
            
            guard !Task.isCancelled else { return }
            // Apply without animation to avoid retaining large old/new caches during transitions.
            self.historyRouteCache = newCache
            
            if let selected = selectedHistoryRoute, newCache[selected.id] == nil {
                selectedHistoryRoute = nil
                viewModel.historyTapCycleState = nil
            }
        }
    }

    private func fetchHistoryDrives(windowStart: Date, now: Date) -> [Drive]? {
        let activeDriveId = stateMachine.activeDrive?.id
        let distantPast = Date.distantPast
        let descriptor = FetchDescriptor<Drive>(
            predicate: #Predicate<Drive> { drive in
                (drive.endTime ?? distantPast) >= windowStart && drive.startTime <= now
            },
            sortBy: [SortDescriptor(\Drive.startTime, order: .reverse)]
        )

        do {
            let fetched = try modelContext.fetch(descriptor)
            guard let activeDriveId else { return fetched }
            return fetched.filter { $0.id != activeDriveId }
        } catch {
            return nil
        }
    }

    private func cancelHistoryCacheTask() {
        viewModel.historyCacheTask?.cancel()
        viewModel.historyCacheTask = nil
    }

    private func downsampleHistoryOverlayCoordinates(
        _ coordinates: [CLLocationCoordinate2D]
    ) -> [CLLocationCoordinate2D] {
        let count = coordinates.count
        guard count > maxHistoryOverlayPointsPerRoute, maxHistoryOverlayPointsPerRoute > 2 else {
            return coordinates
        }

        let target = maxHistoryOverlayPointsPerRoute
        let step = Double(count - 1) / Double(target - 1)
        var result: [CLLocationCoordinate2D] = []
        result.reserveCapacity(target)

        for index in 0..<target {
            let sourceIndex = Int(round(Double(index) * step))
            let clampedIndex = min(max(sourceIndex, 0), count - 1)
            result.append(coordinates[clampedIndex])
        }

        return result
    }

    private func downsampleHistoryHitTestCoordinates(
        _ coordinates: [CLLocationCoordinate2D]
    ) -> [CLLocationCoordinate2D] {
        let count = coordinates.count
        guard count > maxHistoryHitTestPointsPerRoute, maxHistoryHitTestPointsPerRoute > 2 else {
            return coordinates
        }

        let target = maxHistoryHitTestPointsPerRoute
        let step = Double(count - 1) / Double(target - 1)
        var result: [CLLocationCoordinate2D] = []
        result.reserveCapacity(target)

        for index in 0..<target {
            let sourceIndex = Int(round(Double(index) * step))
            let clampedIndex = min(max(sourceIndex, 0), count - 1)
            result.append(coordinates[clampedIndex])
        }

        return result
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
        let candidates = historyRouteCandidates(
            to: coordinate,
            thresholdMeters: thresholdMeters,
            limit: 2
        )
        guard let selectedId = resolveSelectedHistoryRouteId(
            from: candidates,
            tapCoordinate: coordinate,
            thresholdMeters: thresholdMeters
        ) else {
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
            viewModel.historyTapCycleState = nil
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                bottomBarDetent = .peek
            }
            return
        }

        // Same-route retap: re-fit immediately with a short animation.
        if selectedHistoryRoute?.id == selectedId || viewModel.lastFocusedRouteId == selectedId {
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
        viewModel.routeFocusTask = Task { @MainActor in
            defer { viewModel.routeFocusTask = nil }
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
        viewModel.routeFocusTask?.cancel()
        viewModel.routeFocusTask = nil
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
        viewModel.lastFocusedRouteId = routeId
    }
    
    private func historyRouteCandidates(
        to coordinate: CLLocationCoordinate2D,
        thresholdMeters: Double,
        limit: Int
    ) -> [HistoryRouteHitCandidate] {
        let tapPoint = MKMapPoint(coordinate)
        let pointsPerMeter = MKMapPointsPerMeterAtLatitude(coordinate.latitude)
        let thresholdMapPoints = thresholdMeters * pointsPerMeter

        var candidates: [HistoryRouteHitCandidate] = []

        for (driveId, route) in historyRouteCache {
            guard route.hitTestPoints.count > 1 else { continue }

            let rect = route.hitTestRect.insetBy(dx: -thresholdMapPoints, dy: -thresholdMapPoints)
            guard rect.contains(tapPoint) else { continue }

            let distanceMapPoints = distanceFrom(point: tapPoint, to: route.hitTestPoints)
            let distanceMeters = distanceMapPoints / pointsPerMeter
            guard distanceMeters <= thresholdMeters else { continue }

            candidates.append(
                HistoryRouteHitCandidate(
                    id: driveId,
                    distanceMeters: distanceMeters,
                    endTime: route.endTime
                )
            )
        }

        return candidates
            .sorted { lhs, rhs in
                if abs(lhs.distanceMeters - rhs.distanceMeters) > 0.5 {
                    return lhs.distanceMeters < rhs.distanceMeters
                }
                return lhs.endTime > rhs.endTime
            }
            .prefix(max(1, limit))
            .map { $0 }
    }

    private func resolveSelectedHistoryRouteId(
        from candidates: [HistoryRouteHitCandidate],
        tapCoordinate: CLLocationCoordinate2D,
        thresholdMeters: Double
    ) -> UUID? {
        guard !candidates.isEmpty else {
            viewModel.historyTapCycleState = nil
            return nil
        }

        let topIds = Array(candidates.prefix(2).map(\.id))
        let now = Date()

        guard topIds.count == 2 else {
            viewModel.historyTapCycleState = nil
            return topIds.first
        }

        let allowedAnchorDistance = max(
            tapCycleAnchorMinDistanceMeters,
            thresholdMeters * 0.45
        )

        if var cycleState = viewModel.historyTapCycleState,
           cycleState.candidateIds == topIds,
           now.timeIntervalSince(cycleState.timestamp) <= tapCycleMaxInterval,
           centerDistanceMeters(from: cycleState.anchor, to: tapCoordinate) <= allowedAnchorDistance {
            let selectedId = cycleState.candidateIds[cycleState.nextIndex]
            cycleState.nextIndex = (cycleState.nextIndex + 1) % cycleState.candidateIds.count
            cycleState.anchor = tapCoordinate
            cycleState.timestamp = now
            viewModel.historyTapCycleState = cycleState
            return selectedId
        }

        // First tap in a cluster selects the nearest route.
        viewModel.historyTapCycleState = HistoryRouteTapCycleState(
            anchor: tapCoordinate,
            timestamp: now,
            candidateIds: topIds,
            nextIndex: 1
        )
        return topIds[0]
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
        guard let drive = fetchDrive(by: driveId) else { return nil }
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

    private func fetchDrive(by driveId: UUID) -> Drive? {
        let descriptor = FetchDescriptor<Drive>(
            predicate: #Predicate<Drive> { drive in
                drive.id == driveId
            }
        )
        return try? modelContext.fetch(descriptor).first
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
    let hitTestPoints: [MKMapPoint]
    let hitTestRect: MKMapRect
}

private struct HistoryRouteHitCandidate {
    let id: UUID
    let distanceMeters: Double
    let endTime: Date
}

private struct HistoryRouteTapCycleState {
    var anchor: CLLocationCoordinate2D
    var timestamp: Date
    let candidateIds: [UUID]
    var nextIndex: Int
}

@MainActor
private final class DashboardViewModel: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    let cameraRuntime = DashboardCameraRuntime()

    var routeSyncTask: Task<Void, Never>?
    var routeLagBeganAt: Date?
    var lastRouteWatchdogRecoveryAt: Date = .distantPast

    var historyCacheTask: Task<Void, Never>?
    var routeFocusTask: Task<Void, Never>?
    var lastFocusedRouteId: UUID?
    var historyTapCycleState: HistoryRouteTapCycleState?
}

@MainActor
private final class DashboardCameraRuntime {
    var lastManualTrackingDisengageAt: Date?
    var lastCameraUpdate: Date = .distantPast
    var lastHeadingCameraUpdate: Date = .distantPast
    var lastCourseHeading: Double = 0
    var hasCourseHeading: Bool = false
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
    let placeId: UUID
    let placeName: String
    let placeIcon: String
    let startedAt: Date
}

private struct SoftDwellCandidate {
    let key: String
    let placeId: UUID
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
