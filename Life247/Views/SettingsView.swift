//
//  SettingsView.swift
//  Life247
//
//  Created by Andrew Robertson on 1/14/26.
//

import SwiftUI

/// App settings view
struct SettingsView: View {
    @ObservedObject private var airplaneMode = AirplaneModeManager.shared
    @AppStorage("showSpeedHeatMap") private var showSpeedHeatMap = false
    @AppStorage("defaultZoomLevel") private var defaultZoomLevel: String = MapZoomLevel.neighborhood.rawValue
    
    private var selectedZoomLevel: MapZoomLevel {
        MapZoomLevel(rawValue: defaultZoomLevel) ?? .neighborhood
    }
    
    var body: some View {
        NavigationStack {
            List {
                // Airplane Mode Toggle
                Section {
                    Toggle(isOn: $airplaneMode.isEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Airplane Mode")
                            Text("Disables all detection and background processing")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Global")
                }
                
                // Drive Detection Settings
                Section {
                    NavigationLink {
                        DriveDetectionSettingsView()
                    } label: {
                        Label("Drive Detection", systemImage: "car.fill")
                    }
                } header: {
                    Text("Tracking")
                }
                
                // Places
                Section {
                    NavigationLink {
                        PlacesView()
                    } label: {
                        Label("Places", systemImage: "mappin.circle.fill")
                    }
                } header: {
                    Text("Locations")
                }
                
                // Notifications
                Section {
                    Toggle("Drive Started", isOn: Binding(
                        get: { NotificationService.shared.notifyOnStart },
                        set: { enabled in
                            if enabled {
                                Task {
                                    let granted = await NotificationService.shared.requestPermissionIfNeeded()
                                    NotificationService.shared.notifyOnStart = granted
                                }
                            } else {
                                NotificationService.shared.notifyOnStart = false
                            }
                        }
                    ))
                    
                    Toggle("Drive Ended", isOn: Binding(
                        get: { NotificationService.shared.notifyOnEnd },
                        set: { enabled in
                            if enabled {
                                Task {
                                    let granted = await NotificationService.shared.requestPermissionIfNeeded()
                                    NotificationService.shared.notifyOnEnd = granted
                                }
                            } else {
                                NotificationService.shared.notifyOnEnd = false
                            }
                        }
                    ))
                } header: {
                    Text("Notifications")
                }
                
                // Privacy
                Section {
                    NavigationLink {
                        Text("Privacy Settings")
                            .navigationTitle("Privacy")
                    } label: {
                        Label("Privacy Zones", systemImage: "eye.slash.fill")
                    }
                } header: {
                    Text("Privacy")
                }
                
                // Display
                Section {
                    Toggle(isOn: $showSpeedHeatMap) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Speed Heat Map")
                            Text("Colors route lines based on speed in history views")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Picker(selection: $defaultZoomLevel) {
                        ForEach(MapZoomLevel.allCases) { level in
                            Text(level.label).tag(level.rawValue)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Default Zoom")
                            Text(selectedZoomLevel.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Display")
                }
                
                // About
                Section {
                    NavigationLink {
                        ProjectStructureView()
                    } label: {
                        HStack {
                            Text("Version")
                            Spacer()
                            Text("1.0")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .contentMargins(.bottom, 160, for: .scrollContent)  // Space for expanded NavBar
        }
    }
}

#Preview {
    SettingsView()
}
