//
//  SettingsView.swift
//  Life247
//
//  Created by Andrew Robertson on 1/14/26.
//

import SwiftUI

/// App settings view with clean, modern design
struct SettingsView: View {
    @ObservedObject private var airplaneMode = AirplaneModeManager.shared
    @AppStorage("showSpeedHeatMap") private var showSpeedHeatMap = false
    @AppStorage("defaultZoomLevel") private var defaultZoomLevel: String = MapZoomLevel.neighborhood.rawValue
    @AppStorage("notifyOnStart") private var notifyOnStart = true
    @AppStorage("notifyOnEnd") private var notifyOnEnd = true
    
    private var selectedZoomLevel: MapZoomLevel {
        MapZoomLevel(rawValue: defaultZoomLevel) ?? .neighborhood
    }
    
    var body: some View {
        NavigationStack {
            List {
                // Global Controls
                Section {
                    // Airplane Mode
                    HStack(spacing: 12) {
                        Image(systemName: "airplane")
                            .font(.title3)
                            .foregroundStyle(.orange)
                            .frame(width: 28)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Airplane Mode")
                            Text("Pause all tracking")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        Toggle("", isOn: $airplaneMode.isEnabled)
                            .labelsHidden()
                    }
                }
                
                // Tracking & Locations
                Section {
                    NavigationLink {
                        DriveDetectionSettingsView()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "car.fill")
                                .font(.title3)
                                .foregroundStyle(.blue)
                                .frame(width: 28)
                            Text("Drive Detection")
                        }
                    }
                    
                    NavigationLink {
                        PlacesView()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.red)
                                .frame(width: 28)
                            Text("Saved Places")
                        }
                    }
                } header: {
                    Text("Tracking")
                }
                
                // Notifications
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "bell.badge.fill")
                            .font(.title3)
                            .foregroundStyle(.green)
                            .frame(width: 28)
                        Text("Drive Started")
                        Spacer()
                        Toggle("", isOn: $notifyOnStart)
                            .labelsHidden()
                            .onChange(of: notifyOnStart) { _, enabled in
                                handleNotificationToggle(enabled: enabled, isStart: true)
                            }
                    }
                    
                    HStack(spacing: 12) {
                        Image(systemName: "flag.checkered")
                            .font(.title3)
                            .foregroundStyle(.purple)
                            .frame(width: 28)
                        Text("Drive Ended")
                        Spacer()
                        Toggle("", isOn: $notifyOnEnd)
                            .labelsHidden()
                            .onChange(of: notifyOnEnd) { _, enabled in
                                handleNotificationToggle(enabled: enabled, isStart: false)
                            }
                    }
                } header: {
                    Text("Notifications")
                }
                
                // Display
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "thermometer.medium")
                            .font(.title3)
                            .foregroundStyle(.orange)
                            .frame(width: 28)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Speed Heat Map")
                            Text("Color routes by speed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        Toggle("", isOn: $showSpeedHeatMap)
                            .labelsHidden()
                    }
                    
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.title3)
                            .foregroundStyle(.blue)
                            .frame(width: 28)
                        
                        Text("Default Zoom")
                        
                        Spacer()
                        
                        Picker("", selection: $defaultZoomLevel) {
                            ForEach(MapZoomLevel.allCases) { level in
                                Text(level.label).tag(level.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                } header: {
                    Text("Display")
                }
                
                // About
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "info.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.gray)
                            .frame(width: 28)
                        Text("Version")
                        Spacer()
                        Text("1.0")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .contentMargins(.bottom, 100, for: .scrollContent)
        }
    }
    
    // MARK: - Helpers
    
    private func handleNotificationToggle(enabled: Bool, isStart: Bool) {
        if enabled {
            Task {
                let granted = await NotificationService.shared.requestPermissionIfNeeded()
                await MainActor.run {
                    if isStart {
                        NotificationService.shared.notifyOnStart = granted
                        if !granted { notifyOnStart = false }
                    } else {
                        NotificationService.shared.notifyOnEnd = granted
                        if !granted { notifyOnEnd = false }
                    }
                }
            }
        } else {
            if isStart {
                NotificationService.shared.notifyOnStart = false
            } else {
                NotificationService.shared.notifyOnEnd = false
            }
        }
    }
}

#Preview {
    SettingsView()
}
