//
//  ProjectStructureView.swift
//  Life247
//
//  Created by Andrew Robertson on 1/15/26.
//

import SwiftUI

/// Developer easter egg: shows project file structure with descriptions.
struct ProjectStructureView: View {
    @State private var expandedFolders: Set<String> = ["Life247"]
    
    var body: some View {
        List {
            // Root
            DisclosureGroup(isExpanded: binding(for: "Life247")) {
                // App Entry
                FileRow(name: "Life247App.swift", icon: "app.fill", description: "App entry point, SwiftData setup")
                FileRow(name: "ContentView.swift", icon: "rectangle.split.3x1", description: "Main container with tab navigation")
                
                // Core
                FolderRow(name: "Core", isExpanded: binding(for: "Core")) {
                    FileRow(name: "DriveState.swift", icon: "gearshape", description: "Drive state enum (idle, driving, etc.)")
                    FileRow(name: "DriveStateMachine.swift", icon: "arrow.triangle.swap", description: "State machine for drive detection")
                    FileRow(name: "DriveEvent.swift", icon: "bolt.fill", description: "Events that trigger state changes")
                    FileRow(name: "TimerKind.swift", icon: "timer", description: "Timer types for state machine")
                    FileRow(name: "AirplaneModeManager.swift", icon: "airplane", description: "Airplane mode detection")
                }
                
                // Models
                FolderRow(name: "Models", isExpanded: binding(for: "Models")) {
                    FileRow(name: "Drive.swift", icon: "car.fill", description: "Drive data model (SwiftData)")
                    FileRow(name: "LocationPoint.swift", icon: "mappin", description: "GPS point with speed/altitude")
                    FileRow(name: "Place.swift", icon: "mappin.circle.fill", description: "User-defined named locations")
                    FileRow(name: "TimelineItem.swift", icon: "list.bullet", description: "Unified drive/stop timeline entry")
                    FileRow(name: "AppTab.swift", icon: "square.grid.2x2", description: "Tab bar navigation enum")
                    FileRow(name: "HistoryTimeSpan.swift", icon: "calendar", description: "History filter options")
                    FileRow(name: "DriveDetectionSettings.swift", icon: "slider.horizontal.3", description: "Detection tuning parameters")
                    FileRow(name: "MapZoomLevel.swift", icon: "plus.magnifyingglass", description: "Map zoom presets")
                }
                
                // Services
                FolderRow(name: "Services", isExpanded: binding(for: "Services")) {
                    FileRow(name: "LocationManager.swift", icon: "location.fill", description: "GPS tracking & permissions")
                    FileRow(name: "MotionManager.swift", icon: "figure.walk", description: "CoreMotion activity detection")
                    FileRow(name: "NotificationService.swift", icon: "bell.fill", description: "Local notification handling")
                    FileRow(name: "TimelineBuilder.swift", icon: "clock.arrow.circlepath", description: "Builds timeline from drives")
                    FileRow(name: "FrequentStopAnalyzer.swift", icon: "repeat.circle", description: "Detects repeated stop locations")
                    FileRow(name: "GeocodingCache.swift", icon: "text.magnifyingglass", description: "Caches reverse geocoding")
                    FileRow(name: "LocationInterpolator.swift", icon: "point.topleft.down.to.point.bottomright.curvepath", description: "Smooths GPS data")
                }
                
                // Views
                FolderRow(name: "Views", isExpanded: binding(for: "Views")) {
                    FileRow(name: "DashboardView.swift", icon: "map.fill", description: "Main map with live tracking")
                    FileRow(name: "HistoryView.swift", icon: "clock.fill", description: "Drive history timeline")
                    FileRow(name: "DriveDetailView.swift", icon: "doc.text.fill", description: "Individual drive details")
                    FileRow(name: "StopDetailView.swift", icon: "stop.circle.fill", description: "Stop location details")
                    FileRow(name: "SettingsView.swift", icon: "gearshape.fill", description: "App settings")
                    FileRow(name: "PlacesView.swift", icon: "mappin.and.ellipse", description: "Manage saved places")
                    FileRow(name: "SaveAsPlaceView.swift", icon: "plus.circle.fill", description: "Quick place creation")
                    FileRow(name: "PermissionsView.swift", icon: "lock.shield", description: "Location permission onboarding")
                    FileRow(name: "DriveDetectionSettingsView.swift", icon: "slider.horizontal.3", description: "Detection tuning UI")
                }
                
                // Views/Components
                FolderRow(name: "Views/Components", isExpanded: binding(for: "Components")) {
                    FileRow(name: "NavigationBar.swift", icon: "dock.rectangle", description: "Bottom tab bar with stats")
                    FileRow(name: "MiniRouteMap.swift", icon: "map", description: "Static route snapshots")
                    FileRow(name: "MiniRouteSnapshotRenderer.swift", icon: "photo", description: "Snapshot generation logic")
                    FileRow(name: "StopRowView.swift", icon: "stop.fill", description: "Stop card in timeline")
                    FileRow(name: "RoutePolyline.swift", icon: "line.diagonal", description: "Route line rendering")
                    FileRow(name: "MapCameraPolicy.swift", icon: "camera.viewfinder", description: "Camera tracking modes")
                }
            } label: {
                Label("Life247", systemImage: "folder.fill")
                    .font(.headline)
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.bottom, 160, for: .scrollContent)
        .navigationTitle("Project Structure")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func binding(for folder: String) -> Binding<Bool> {
        Binding(
            get: { expandedFolders.contains(folder) },
            set: { isExpanded in
                if isExpanded {
                    expandedFolders.insert(folder)
                } else {
                    expandedFolders.remove(folder)
                }
            }
        )
    }
}

// MARK: - Row Views

struct FileRow: View {
    let name: String
    let icon: String
    let description: String
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.blue)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .fontDesign(.monospaced)
                
                Text(description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct FolderRow<Content: View>: View {
    let name: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: Content
    
    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content
        } label: {
            Label(name, systemImage: "folder.fill")
                .foregroundStyle(.orange)
        }
    }
}

#Preview {
    NavigationStack {
        ProjectStructureView()
    }
}
