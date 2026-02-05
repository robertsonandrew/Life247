//
//  SettingsView.swift
//  Life247
//
//  Created by Andrew Robertson on 1/14/26.
//

import SwiftUI

// MARK: - Compact Settings Row Components

/// A minimal full-width row for settings with a toggle
private struct SettingsToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.body)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
    }
}

/// A minimal full-width navigation row
private struct SettingsNavRow<Destination: View>: View {
    let title: String
    var subtitle: String? = nil
    let destination: () -> Destination
    
    var body: some View {
        NavigationLink(destination: destination) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.systemBackground))
        }
        .buttonStyle(.plain)
    }
}

/// A minimal full-width row with a picker
private struct SettingsPickerRow<T: Hashable>: View {
    let title: String
    var subtitle: String? = nil
    @Binding var selection: T
    let options: [(label: String, value: T)]
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.body)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Picker("", selection: $selection) {
                ForEach(options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
    }
}

/// A minimal full-width row showing a static value
private struct SettingsValueRow: View {
    let title: String
    let value: String
    
    var body: some View {
        HStack {
            Text(title)
                .font(.body)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
    }
}

/// Compact section header
private struct SettingsSectionHeader: View {
    let title: String
    
    var body: some View {
        Text(title.uppercased())
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 24)
            .padding(.bottom, 6)
    }
}

/// Full-width thin divider
private struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(height: 0.5)
    }
}

// MARK: - Settings View

/// App settings view with clean, compact design
struct SettingsView: View {
    @EnvironmentObject private var syncService: DriveSyncService
    @AppStorage("showSpeedHeatMap") private var showSpeedHeatMap = false
    @AppStorage("showSpeedTrace") private var showSpeedTrace = true
    @AppStorage("showPlacesOnMap") private var showPlacesOnMap = true
    @AppStorage("showPlaceCenterMarkers") private var showPlaceCenterMarkers = false
    @AppStorage("showMapStyleButton") private var showMapStyleButton = false
    @AppStorage("defaultZoomLevel") private var defaultZoomLevel: String = MapZoomLevel.area.rawValue
    @AppStorage("historyTimeSpan") private var historyTimeSpan: String = HistoryTimeSpan.off.rawValue
    @AppStorage("notifyOnStart") private var notifyOnStart = true
    @AppStorage("notifyOnEnd") private var notifyOnEnd = true
    
    @Environment(\.modelContext) private var modelContext

    private var appVersionDisplay: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }

    private var gitCommitDisplay: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "GitCommitHash") as? String else {
            return nil
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.lowercased() != "unknown" else {
            return nil
        }
        return value
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Global Controls
                    SettingsSectionHeader(title: "")
                    
                    AirplaneModeToggleRow()
                    
                    // Tracking
                    SettingsSectionHeader(title: "Tracking")
                    
                    SettingsNavRow(title: "Drive Detection") {
                        DriveDetectionSettingsView()
                    }
                    SettingsDivider()
                    SettingsNavRow(title: "Saved Places") {
                        PlacesView()
                    }
                    
                    // Notifications
                    SettingsSectionHeader(title: "Notifications")
                    
                    NotificationToggleRow(
                        title: "Drive Started",
                        isOn: $notifyOnStart,
                        isStart: true
                    )
                    SettingsDivider()
                    NotificationToggleRow(
                        title: "Drive Ended",
                        isOn: $notifyOnEnd,
                        isStart: false
                    )
                    
                    // Display
                    SettingsSectionHeader(title: "Display")
                    
                    SettingsToggleRow(
                        title: "Show Saved Places",
                        subtitle: "Display place geofence circles on map",
                        isOn: $showPlacesOnMap
                    )
                    SettingsDivider()
                    SettingsToggleRow(
                        title: "Place Center Markers",
                        subtitle: "Show subtle center dots for saved places",
                        isOn: $showPlaceCenterMarkers
                    )
                    SettingsDivider()
                    SettingsToggleRow(
                        title: "Map Style Button",
                        subtitle: "Show map style picker button on dashboard",
                        isOn: $showMapStyleButton
                    )
                    SettingsDivider()
                    SettingsToggleRow(
                        title: "Speed Heat Map",
                        subtitle: "Color routes by speed",
                        isOn: $showSpeedHeatMap
                    )
                    SettingsDivider()
                    SettingsToggleRow(
                        title: "Speed Heatmap in History",
                        subtitle: "Color mini traces by speed on drive cards",
                        isOn: $showSpeedTrace
                    )
                    SettingsDivider()
                    SettingsPickerRow(
                        title: "Default Zoom",
                        selection: $defaultZoomLevel,
                        options: MapZoomLevel.allCases.map { ($0.label, $0.rawValue) }
                    )
                    SettingsDivider()
                    SettingsPickerRow(
                        title: "History Overlay",
                        subtitle: "Show past routes on map",
                        selection: $historyTimeSpan,
                        options: HistoryTimeSpan.allCases.map { ($0.label, $0.rawValue) }
                    )
                    
                    // Backup
                    SettingsSectionHeader(title: "Backup")
                    
                    SyncStatusRow()
                    
                    // About
                    SettingsSectionHeader(title: "About")
                    
                    SettingsValueRow(title: "Version", value: appVersionDisplay)
                    if let gitCommitDisplay {
                        SettingsDivider()
                        SettingsValueRow(title: "Git", value: gitCommitDisplay)
                    }
                    
                    Spacer(minLength: 100)
                }
            }
            .background(Color(.systemGroupedBackground))
            .bottomBarPadding()
            .navigationTitle("Settings")
        }
    }
}

// MARK: - Isolated Subviews (Prevent Parent Re-renders)

/// Isolated airplane mode toggle - only re-renders when its state changes
private struct AirplaneModeToggleRow: View {
    @ObservedObject private var airplaneMode = AirplaneModeManager.shared
    
    var body: some View {
        SettingsToggleRow(
            title: "Airplane Mode",
            subtitle: "Pause all tracking",
            isOn: $airplaneMode.isEnabled
        )
    }
}

/// Isolated sync status row - only re-renders when sync state changes
private struct SyncStatusRow: View {
    @EnvironmentObject private var syncService: DriveSyncService
    
    private var syncStatusText: String {
        if syncService.syncEnabled {
            if syncService.isSyncing {
                return "Syncing..."
            } else if syncService.pendingCount > 0 {
                return "\(syncService.pendingCount) pending"
            } else if syncService.lastError != nil {
                return "Check connection"
            } else {
                return "Up to date"
            }
        } else {
            return "Off"
        }
    }
    
    var body: some View {
        SettingsNavRow(title: "Cloud Sync", subtitle: syncStatusText) {
            CloudSyncSettingsView()
        }
    }
}

/// Isolated notification toggle with async permission handling
private struct NotificationToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    let isStart: Bool
    
    var body: some View {
        SettingsToggleRow(title: title, isOn: $isOn)
            .onChange(of: isOn) { _, enabled in
                handleToggle(enabled: enabled)
            }
    }
    
    private func handleToggle(enabled: Bool) {
        if enabled {
            Task {
                let granted = await NotificationService.shared.requestPermissionIfNeeded()
                await MainActor.run {
                    if isStart {
                        NotificationService.shared.notifyOnStart = granted
                        if !granted { isOn = false }
                    } else {
                        NotificationService.shared.notifyOnEnd = granted
                        if !granted { isOn = false }
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
