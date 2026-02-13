//
//  ContentView.swift
//  Life247
//
//  Created by Andrew Robertson on 1/14/26.
//

import SwiftUI
import SwiftData

/// Main content view with unified bottom bar.
/// BottomBar combines DriveSheet + TabBar as one component.
struct ContentView: View {
    @Bindable var stateMachine: DriveStateMachine
    @ObservedObject var locationManager: LocationManager
    @ObservedObject var motionManager: MotionManager
    
    // Environment
    @Environment(\.scenePhase) var scenePhase
    
    // Tab selection
    @State private var selectedTab: AppTab = .map
    @State private var bottomBarDetent: BottomBarDetent = .peek
    @State private var selectedHistoryRoute: HistoryRouteSelection?
    
    var body: some View {
        Group {
            if !locationManager.hasAlwaysAuthorization {
                PermissionsView(
                    locationManager: locationManager,
                    motionManager: motionManager
                )
            } else {
                mainContent
            }
        }
        .onChange(of: stateMachine.state) { oldState, newState in
            handleStateChange(from: oldState, to: newState)
        }
        .onChange(of: stateMachine.isPostDriveMonitoring) { wasMonitoring, isMonitoring in
            // When post-drive monitoring ends (and we're still idle), disable high-accuracy
            if wasMonitoring && !isMonitoring && stateMachine.state == .idle {
                locationManager.disableHighAccuracy(reason: "driving")
            }
        }
        .onChange(of: selectedTab) { oldTab, newTab in
            // Only enable manual high-accuracy if app is active
            if newTab == .map && scenePhase == .active {
                locationManager.enableHighAccuracy(reason: "mapVisible")
            } else {
                locationManager.disableHighAccuracy(reason: "mapVisible")
            }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .active {
                // Determine if we need to restore map accuracy
                if selectedTab == .map {
                    locationManager.enableHighAccuracy(reason: "mapVisible")
                }
            } else if newPhase == .background || newPhase == .inactive {
                // Disable manual map tracking when backgrounding
                // (Driven high-accuracy is handled separately by StateMachine)
                locationManager.disableHighAccuracy(reason: "mapVisible")
            }
        }
        .onAppear {
            if selectedTab == .map {
                locationManager.enableHighAccuracy(reason: "mapVisible")
            }
        }
    }
    
    // MARK: - Main Content
    
    /// Dynamic bottom bar height (updated via preference from BottomBar)
    @State private var dynamicBottomBarHeight: CGFloat = 112  // Default: tab (56) + peek (56)
    
    private var showDriveSheet: Bool {
        // Drive sheet shows on map tab during active driving states
        true // Always present on map tab, just with different content
    }
    
    private var mainContent: some View {
        // Use ZStack to keep DashboardView alive across tab switches
        // This prevents expensive map recreation that causes freezing
        ZStack {
            // Main Content Layer
            ZStack {
                // Map is always rendered (just hidden when not selected)
                DashboardView(
                    stateMachine: stateMachine,
                    locationManager: locationManager,
                    selectedHistoryRoute: $selectedHistoryRoute,
                    bottomBarDetent: $bottomBarDetent,
                    isVisible: selectedTab == .map
                )
                .opacity(selectedTab == .map ? 1 : 0)
                .zIndex(selectedTab == .map ? 1 : 0)
                .allowsHitTesting(selectedTab == .map)
                
                // Keep history alive across tab switches to avoid repeated timeline cold-builds.
                NavigationStack {
                    HistoryView()
                }
                .opacity(selectedTab == .history ? 1 : 0)
                .zIndex(selectedTab == .history ? 2 : 0)
                .allowsHitTesting(selectedTab == .history)
                
                if selectedTab == .settings {
                    SettingsView()
                        .zIndex(2)
                }
            }
            .environment(\.bottomBarHeight, dynamicBottomBarHeight)
            .animation(nil, value: selectedTab)
            
            // Bottom Bar Layer (Stacked on top)
            VStack {
                Spacer()
                BottomBar(
                    selectedTab: $selectedTab,
                    driveState: stateMachine.state,
                    speed: currentSpeedMPH,
                    distance: currentDistanceMiles,
                    duration: currentDuration,
                    avgSpeed: avgSpeedMPH,
                    maxSpeed: maxSpeedMPH,
                    pointCount: pointCount,
                    onEndDrive: stateMachine.state == .driving || stateMachine.state == .stopped
                        ? { stateMachine.recoverFromStuckDrive() }
                        : nil,
                    showDriveSheet: selectedTab == .map,
                    currentDetent: $bottomBarDetent,
                    selectedHistoryRoute: selectedHistoryRoute,
                    visibleHeight: $dynamicBottomBarHeight
                )
            }
            .animation(nil, value: dynamicBottomBarHeight)
        }
        .onPreferenceChange(BottomBarHeightPreferenceKey.self) { height in
            dynamicBottomBarHeight = height
        }
        .ignoresSafeArea(.keyboard)
    }
    
    // MARK: - Computed Metrics
    
    private var currentSpeedMPH: Double {
        stateMachine.currentSpeedMPH
    }
    
    private var currentDistanceMiles: Double {
        (stateMachine.activeDrive?.distanceMeters ?? 0) / 1609.34
    }
    
    private var currentDuration: TimeInterval {
        guard let drive = stateMachine.activeDrive else { return 0 }
        return Date().timeIntervalSince(drive.startTime)
    }
    
    private var avgSpeedMPH: Double {
        stateMachine.activeDrive?.averageSpeedMPH ?? 0
    }
    
    private var maxSpeedMPH: Double {
        stateMachine.activeDrive?.maxSpeedMPH ?? 0
    }
    
    private var pointCount: Int {
        stateMachine.activeDrive?.points.count ?? 0
    }
    
    // MARK: - State Handling
    
    private func handleStateChange(from oldState: DriveState, to newState: DriveState) {
        switch newState {
        case .maybeDriving, .driving, .stopped, .pendingArrival:
            locationManager.enableHighAccuracy(reason: "driving")
            
        case .ended:
            // Don't disable high-accuracy immediately - let post-drive monitoring handle it
            // The stateMachine.isPostDriveMonitoring flag will be true
            break
            
        case .idle:
            // coldStart should always be released when going to idle
            // (it's only for the initial recovery, not post-drive monitoring)
            locationManager.disableHighAccuracy(reason: "coldStart")
            
            // Only disable driving high-accuracy if we're not in post-drive monitoring
            // (post-drive monitoring keeps tracking briefly to catch false arrivals)
            if !stateMachine.isPostDriveMonitoring {
                locationManager.disableHighAccuracy(reason: "driving")
            }
        }
    }
}

#Preview {
    ContentView(
        stateMachine: DriveStateMachine(),
        locationManager: LocationManager(),
        motionManager: MotionManager()
    )
    .modelContainer(for: Drive.self, inMemory: true)
}
