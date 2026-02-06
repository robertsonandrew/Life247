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
    @AppStorage("notifyOnDriveStart") private var notifyOnStart = true
    @AppStorage("notifyOnDriveEnd") private var notifyOnEnd = true
    @AppStorage("notifyDriveStartSound") private var notifyDriveStartSoundRaw = NotificationSoundOption.triTone.rawValue
    @AppStorage("notifyDriveEndSound") private var notifyDriveEndSoundRaw = NotificationSoundOption.chord.rawValue
    @AppStorage("showPlacesOnMap") private var showPlacesOnMap = true
    @AppStorage("defaultZoomLevel") private var defaultZoomLevel: String = MapZoomLevel.area.rawValue
    @AppStorage("historyTimeSpan") private var historyTimeSpan: String = HistoryTimeSpan.off.rawValue

    private var appVersionDisplay: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }

    private var gitCommitDisplay: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "GitCommitHash") as? String ?? ""
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value.caseInsensitiveCompare("unknown") == .orderedSame {
            return "not embedded"
        }
        return value
    }

    private var startSoundOption: NotificationSoundOption {
        NotificationSoundOption(rawValue: notifyDriveStartSoundRaw) ?? .triTone
    }

    private var endSoundOption: NotificationSoundOption {
        NotificationSoundOption(rawValue: notifyDriveEndSoundRaw) ?? .chord
    }

    private var notificationsSubtitle: String {
        let startText = notifyOnStart ? startSoundOption.label : "Off"
        let endText = notifyOnEnd ? endSoundOption.label : "Off"
        return "Start: \(startText), End: \(endText)"
    }

    private var zoomLevelOption: MapZoomLevel {
        MapZoomLevel(rawValue: defaultZoomLevel) ?? .area
    }

    private var historyTimeSpanOption: HistoryTimeSpan {
        HistoryTimeSpan(rawValue: historyTimeSpan) ?? .off
    }

    private var mapAppearanceSubtitle: String {
        let placesText = showPlacesOnMap ? "Places On" : "Places Off"
        let historyText = "History \(historyTimeSpanOption.label)"
        let zoomText = "Zoom \(zoomLevelOption.label)"
        return "\(placesText), \(historyText), \(zoomText)"
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
                    
                    // Preferences
                    SettingsSectionHeader(title: "Preferences")

                    SettingsNavRow(
                        title: "Notifications",
                        subtitle: notificationsSubtitle
                    ) {
                        NotificationsSettingsView()
                    }
                    SettingsDivider()
                    SettingsNavRow(
                        title: "Map Appearance",
                        subtitle: mapAppearanceSubtitle
                    ) {
                        MapAppearanceSettingsView()
                    }

                    // Backup
                    SettingsSectionHeader(title: "Backup")

                    SyncStatusRow()

                    // About
                    SettingsSectionHeader(title: "About")

                    SettingsValueRow(title: "Version", value: appVersionDisplay)
                    SettingsDivider()
                    SettingsValueRow(title: "Git", value: gitCommitDisplay)
                    
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

private struct NotificationsSettingsView: View {
    @AppStorage("notifyOnDriveStart") private var notifyOnStart = true
    @AppStorage("notifyOnDriveEnd") private var notifyOnEnd = true

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                SettingsSectionHeader(title: "Drive Events")

                NotificationToggleRow(
                    title: "Drive Started",
                    isOn: $notifyOnStart,
                    isStart: true
                )
                SettingsDivider()
                NotificationSoundPickerRow(
                    title: "Start Sound",
                    isStart: true
                )
                SettingsDivider()
                NotificationToggleRow(
                    title: "Drive Ended",
                    isOn: $notifyOnEnd,
                    isStart: false
                )
                SettingsDivider()
                NotificationSoundPickerRow(
                    title: "End Sound",
                    isStart: false
                )

                Spacer(minLength: 100)
            }
        }
        .background(Color(.systemGroupedBackground))
        .bottomBarPadding()
        .navigationTitle("Notifications")
    }
}

private struct MapAppearanceSettingsView: View {
    @AppStorage("showSpeedHeatMap") private var showSpeedHeatMap = false
    @AppStorage("showSpeedTrace") private var showSpeedTrace = true
    @AppStorage("showPlacesOnMap") private var showPlacesOnMap = true
    @AppStorage("showPlaceCenterMarkers") private var showPlaceCenterMarkers = false
    @AppStorage("showMapStyleButton") private var showMapStyleButton = false
    @AppStorage("defaultZoomLevel") private var defaultZoomLevel: String = MapZoomLevel.area.rawValue
    @AppStorage("historyTimeSpan") private var historyTimeSpan: String = HistoryTimeSpan.off.rawValue

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                SettingsSectionHeader(title: "Map")

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

                SettingsSectionHeader(title: "Routes")

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
                    title: "History Overlay",
                    subtitle: "Show past routes on map",
                    selection: $historyTimeSpan,
                    options: HistoryTimeSpan.allCases.map { ($0.label, $0.rawValue) }
                )

                SettingsSectionHeader(title: "Camera")

                SettingsPickerRow(
                    title: "Default Zoom",
                    selection: $defaultZoomLevel,
                    options: MapZoomLevel.allCases.map { ($0.label, $0.rawValue) }
                )

                Spacer(minLength: 100)
            }
        }
        .background(Color(.systemGroupedBackground))
        .bottomBarPadding()
        .navigationTitle("Map Appearance")
    }
}

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

/// Isolated notification sound picker for start/end events
private struct NotificationSoundPickerRow: View {
    let title: String
    let isStart: Bool
    @ObservedObject private var notificationService = NotificationService.shared

    private var selection: Binding<NotificationSoundOption> {
        Binding(
            get: {
                isStart ? notificationService.startSound : notificationService.endSound
            },
            set: { newValue in
                if isStart {
                    notificationService.startSound = newValue
                } else {
                    notificationService.endSound = newValue
                }
            }
        )
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.body)
            Spacer()
            Picker("", selection: selection) {
                ForEach(NotificationSoundOption.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            Button {
                let sound = isStart ? notificationService.startSound : notificationService.endSound
                Task { @MainActor in
                    notificationService.preview(sound: sound)
                }
            } label: {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Preview sound")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
    }
}

#Preview {
    SettingsView()
}
