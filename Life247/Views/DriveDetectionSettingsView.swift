//
//  DriveDetectionSettingsView.swift
//  Life247
//
//  Created by Andrew Robertson on 1/14/26.
//

import SwiftUI

/// View for adjusting drive detection parameters
/// Uses segmented pickers with preset values for a more compact, responsive UI
struct DriveDetectionSettingsView: View {
    @State private var settings = DriveDetectionSettings()
    @State private var showResetConfirmation = false
    
    // Preset options for each setting
    private let stoppedDetectionPresets: [Double] = [15, 30, 60, 90]
    private let autoEndPresets: [Int] = [3, 5, 10, 15]
    private let confirmationPresets: [Double] = [5, 10, 15, 20]
    
    var body: some View {
        List {
            // Stopped Detection
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "pause.circle.fill")
                            .foregroundStyle(.orange)
                        Text("Stop Detection")
                            .fontWeight(.medium)
                        Spacer()
                        Text("\(Int(settings.stoppedDetectionDuration))s")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    
                    Picker("", selection: $settings.stoppedDetectionDuration) {
                        ForEach(stoppedDetectionPresets, id: \.self) { value in
                            Text("\(Int(value))s").tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            } footer: {
                Text("Time at low speed before entering stopped state")
            }
            
            // Auto-End Drive
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "stop.circle.fill")
                            .foregroundStyle(.red)
                        Text("Auto-End")
                            .fontWeight(.medium)
                        Spacer()
                        Text("\(settings.stoppedTimeoutMinutes) min")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    
                    Picker("", selection: $settings.stoppedTimeoutMinutes) {
                        ForEach(autoEndPresets, id: \.self) { value in
                            Text("\(value)m").tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            } footer: {
                Text("Time at rest before a drive ends automatically")
            }
            
            // Drive Confirmation
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "play.circle.fill")
                            .foregroundStyle(.green)
                        Text("Start Detection")
                            .fontWeight(.medium)
                        Spacer()
                        Text("\(Int(settings.drivingConfirmationDuration))s")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    
                    Picker("", selection: $settings.drivingConfirmationDuration) {
                        ForEach(confirmationPresets, id: \.self) { value in
                            Text("\(Int(value))s").tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            } footer: {
                Text("Time at driving speed before recording starts")
            }
            
            // Reset Section
            Section {
                Button("Reset to Defaults", role: .destructive) {
                    showResetConfirmation = true
                }
            }
        }
        .contentMargins(.bottom, 100, for: .scrollContent)
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
