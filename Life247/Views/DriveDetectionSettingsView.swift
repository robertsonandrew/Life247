//
//  DriveDetectionSettingsView.swift
//  Life247
//
//  Created by Andrew Robertson on 1/14/26.
//

import SwiftUI

/// View for adjusting drive detection parameters
struct DriveDetectionSettingsView: View {
    @State private var settings = DriveDetectionSettings()
    @State private var showResetConfirmation = false
    
    var body: some View {
        List {
            // Stopped Detection Duration
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Duration")
                        Spacer()
                        Text("\(Int(settings.stoppedDetectionDuration))s")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    
                    Slider(
                        value: $settings.stoppedDetectionDuration,
                        in: DriveDetectionSettings.stoppedDetectionRange,
                        step: 5
                    )
                }
            } header: {
                Text("Stopped Detection")
            } footer: {
                Text("How long at low speed before entering \"stopped\" state. Lower = faster detection, higher = ignores brief stops.")
            }
            
            // Stopped Timeout
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Timeout")
                        Spacer()
                        Text("\(settings.stoppedTimeoutMinutes) min")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    
                    Slider(
                        value: Binding(
                            get: { Double(settings.stoppedTimeoutMinutes) },
                            set: { settings.stoppedTimeoutMinutes = Int($0) }
                        ),
                        in: Double(DriveDetectionSettings.stoppedTimeoutRange.lowerBound)...Double(DriveDetectionSettings.stoppedTimeoutRange.upperBound),
                        step: 1
                    )
                }
            } header: {
                Text("Auto-End Drive")
            } footer: {
                Text("How long stopped before automatically ending a drive. Increase if you make frequent quick stops.")
            }
            
            // Driving Confirmation Duration
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Duration")
                        Spacer()
                        Text("\(Int(settings.drivingConfirmationDuration))s")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    
                    Slider(
                        value: $settings.drivingConfirmationDuration,
                        in: DriveDetectionSettings.drivingConfirmationRange,
                        step: 5
                    )
                }
            } header: {
                Text("Drive Confirmation")
            } footer: {
                Text("How long you must maintain driving speed before a drive starts recording. Lower = quicker detection, higher = fewer false starts.")
            }
            
            // Reset Section
            Section {
                Button("Reset to Defaults", role: .destructive) {
                    showResetConfirmation = true
                }
            }
        }
        .navigationTitle("Drive Detection")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Reset all settings to defaults?",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                settings.resetToDefaults()
            }
            Button("Cancel", role: .cancel) { }
        }
    }
}

#Preview {
    NavigationStack {
        DriveDetectionSettingsView()
    }
}
