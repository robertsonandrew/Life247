//
//  ContentView.swift
//  Life247
//
//  Created by Andrew Robertson on 1/14/26.
//

import SwiftUI
import SwiftData

/// Main content view with tab-based navigation via NavigationBar.
/// ContentView is the ONLY owner of selectedTab state.
struct ContentView: View {
    @Bindable var stateMachine: DriveStateMachine
    @ObservedObject var locationManager: LocationManager
    @ObservedObject var motionManager: MotionManager
    
    // Single source of truth for navigation
    @State private var selectedTab: AppTab = .map
    @State private var isNavBarExpanded: Bool = true
    
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
    }
    
    private var mainContent: some View {
        // Active tab view (rendered based on selectedTab)
        Group {
            switch selectedTab {
            case .map:
                DashboardView(
                    stateMachine: stateMachine,
                    locationManager: locationManager
                )
                
            case .history:
                NavigationStack {
                    HistoryView()
                }
                
            case .settings:
                SettingsView()
            }
        }
        // No animation on tab switch
        .animation(nil, value: selectedTab)
        // Navigation bar as safe area inset so MapKit can position attribution correctly
        .safeAreaInset(edge: .bottom) {
            NavigationBar(
                selectedTab: $selectedTab,
                isExpanded: $isNavBarExpanded,
                driveState: stateMachine.state,
                speed: currentSpeedMPH,
                distance: currentDistanceMiles,
                duration: currentDuration,
                avgSpeed: avgSpeedMPH,
                maxSpeed: maxSpeedMPH,
                pointCount: pointCount,
                onEndDrive: stateMachine.state == .driving || stateMachine.state == .stopped
                    ? { stateMachine.recoverFromStuckDrive() }
                    : nil
            )
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
        case .maybeDriving, .driving, .stopped:
            locationManager.enableHighAccuracyMode()
            
        case .idle, .ended:
            locationManager.disableHighAccuracyMode()
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
