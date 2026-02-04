//
//  CloudSyncSettingsView.swift
//  Life247
//
//  Created by Andrew Robertson on 1/17/26.
//

import SwiftUI
import SwiftData

struct CloudSyncSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var syncService: DriveSyncService

    @Query(sort: \Drive.startTime, order: .reverse) private var allDrives: [Drive]
    @Query private var allPlaces: [Place]
    @Query(sort: \PlaceVisit.arrivalTime, order: .reverse) private var allPlaceVisits: [PlaceVisit]
    
    @AppStorage("syncEnabled") private var syncEnabled: Bool = false
    @AppStorage("syncServerURL") private var serverURL: String = ""
    @AppStorage("syncAPIKey") private var apiKey: String = ""
    @AppStorage("syncOnWiFiOnly") private var syncOnWiFiOnly: Bool = true
    
    @State private var showResetConfirmation = false

    @State private var showBackfillConfirmation = false
    @State private var isBackfillingVisits = false
    @State private var backfillResultText: String?
    @State private var backfillDays: Int = 180
    
    private var unsyncedDriveCount: Int {
        allDrives.filter { $0.endTime != nil && $0.syncStatus != "synced" }.count
    }
    
    private var unsyncedVisitCount: Int {
        allPlaceVisits.filter { $0.departureTime != nil && $0.syncStatus != "synced" }.count
    }
    
    var body: some View {
        Form {
            Section {
                Toggle("Enable Sync", isOn: $syncEnabled)
                    .tint(.blue)
            } footer: {
                Text("Automatically backup your completed drives and place visits to your self-hosted server.")
            }
            
            if syncEnabled {
                Section("Configuration") {
                    TextField("Server URL", text: $serverURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .textContentType(.URL)
                    
                    SecureField("API Key", text: $apiKey)
                        .textContentType(.password)
                    
                    Toggle("WiFi Only", isOn: $syncOnWiFiOnly)
                        .tint(.blue)
                }
                
                Section("Status") {
                    HStack {
                        Label("Connection", systemImage: "server.rack")
                        Spacer()
                        if syncService.connectionTested {
                            Text(syncService.connectionSuccess ? "Connected" : "Failed")
                                .foregroundStyle(syncService.connectionSuccess ? .green : .red)
                        } else {
                            Text("Unknown")
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    if let error = syncService.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    
                    Button("Test Connection") {
                        Task { _ = await syncService.testConnection() }
                    }
                }
                
                Section("Sync Queue") {
                    // Summary row
                    HStack {
                        Label("Pending", systemImage: "tray.full")
                        Spacer()
                        Text("\(syncService.pendingCount) queued")
                            .foregroundStyle(.secondary)
                    }
                    
                    HStack {
                        Label("Unsynced", systemImage: "exclamationmark.circle")
                        Spacer()
                        Text("\(unsyncedDriveCount) drives, \(unsyncedVisitCount) visits")
                            .foregroundStyle(.secondary)
                    }
                    
                    if let lastSync = syncService.lastSyncDate {
                        HStack {
                            Label("Last Synced", systemImage: "clock")
                            Spacer()
                            Text(lastSync.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    // Progress indicator during sync
                    if let progress = syncService.syncProgress {
                        HStack {
                            Text("Uploading \(progress.current)/\(progress.total)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            ProgressView(value: Double(progress.current), total: Double(progress.total))
                                .frame(width: 100)
                        }
                    }
                    
                    // Main sync button - syncs everything
                    Button {
                        Task { await syncService.syncAll(modelContext: modelContext) }
                    } label: {
                        HStack {
                            if syncService.isSyncing {
                                Text("Syncing...")
                                Spacer()
                                ProgressView()
                            } else {
                                Label("Sync All", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                    }
                    .disabled(syncService.isSyncing)
                }
                
                Section {
                    // Reset sync status
                    Button("Reset & Re-upload Everything") {
                        showResetConfirmation = true
                    }
                    .disabled(syncService.isSyncing)
                    .foregroundStyle(.orange)
                    .confirmationDialog("Reset Sync Status?", isPresented: $showResetConfirmation) {
                        Button("Reset & Upload All", role: .destructive) {
                            Task {
                                await syncService.resetAllSyncStatus(modelContext: modelContext)
                            }
                        }
                        Button("Cancel", role: .cancel) { }
                    } message: {
                        Text("This will mark all local drives AND place visits as pending and attempt to upload them to the server again. Use this if you reset your server database.")
                    }
                    
                    // Backfill place visits
                    DisclosureGroup("Backfill Place Visits") {
                        Stepper("Window: \(backfillDays) days", value: $backfillDays, in: 30...365, step: 30)
                            .disabled(isBackfillingVisits)
                        
                        Button {
                            showBackfillConfirmation = true
                        } label: {
                            if isBackfillingVisits {
                                HStack {
                                    Text("Backfilling…")
                                    Spacer()
                                    ProgressView()
                                }
                            } else {
                                Label("Run Backfill", systemImage: "clock.arrow.circlepath")
                            }
                        }
                        .disabled(isBackfillingVisits)
                        .confirmationDialog("Backfill Place Visits?", isPresented: $showBackfillConfirmation) {
                            Button("Backfill", role: .destructive) {
                                Task { await backfillPlaceVisits(days: backfillDays) }
                            }
                            Button("Cancel", role: .cancel) { }
                        } message: {
                            Text("This infers stops between your existing drives and creates Place Visits for stops that match a saved Place. Safe to run multiple times.")
                        }

                        if let backfillResultText {
                            Text(backfillResultText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Maintenance")
                } footer: {
                    Text("Recovery tools for database resets or historical data reconstruction.")
                }
            }
        }
        .navigationTitle("Cloud Sync")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Backfill

    @MainActor
    private func backfillPlaceVisits(days: Int) async {
        guard !isBackfillingVisits else { return }
        isBackfillingVisits = true
        backfillResultText = nil
        defer { isBackfillingVisits = false }

        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())

        let drives = allDrives
            .filter { $0.endTime != nil }
            .filter { drive in
                guard let cutoff else { return true }
                return drive.startTime >= cutoff
            }

        let places = allPlaces

        // Build a dedupe set of existing completed visits
        var existingKeys = Set<String>()
        for visit in allPlaceVisits {
            guard let dep = visit.departureTime else { continue }
            existingKeys.insert(backfillKey(
                placeName: visit.placeName,
                placeLatitude: visit.placeLatitude,
                placeLongitude: visit.placeLongitude,
                arrivalTime: visit.arrivalTime,
                departureTime: dep
            ))
        }

        let timeline = await TimelineBuilder.buildTimeline(drives: drives, places: places)

        let inferredStops: [InferredStop] = timeline.compactMap { item in
            if case .stop(let stop) = item { return stop }
            return nil
        }

        var created = 0
        var skipped = 0

        for stop in inferredStops {
            guard let place = stop.matchedPlace else { continue }
            let key = backfillKey(
                placeName: place.name,
                placeLatitude: place.latitude,
                placeLongitude: place.longitude,
                arrivalTime: stop.startTime,
                departureTime: stop.endTime
            )

            guard !existingKeys.contains(key) else {
                skipped += 1
                continue
            }

            let visit = PlaceVisit(
                arrivalTime: stop.startTime,
                departureTime: stop.endTime,
                coordinate: stop.location,
                place: place,
                source: "backfill"
            )
            modelContext.insert(visit)
            existingKeys.insert(key)
            created += 1

            // Queue for upload (only syncs completed visits)
            syncService.queuePlaceVisit(visit)
        }

        do {
            try modelContext.save()
        } catch {
            backfillResultText = "Backfill failed to save: \(error.localizedDescription)"
            return
        }

        backfillResultText = "Created \(created) visits, skipped \(skipped) duplicates."
    }

    private func backfillKey(
        placeName: String,
        placeLatitude: Double,
        placeLongitude: Double,
        arrivalTime: Date,
        departureTime: Date
    ) -> String {
        let a = Int(arrivalTime.timeIntervalSince1970)
        let d = Int(departureTime.timeIntervalSince1970)
        return "\(placeName)|\(placeLatitude)|\(placeLongitude)|\(a)|\(d)"
    }
}

#Preview {
    NavigationStack {
        CloudSyncSettingsView()
            .environmentObject(DriveSyncService())
    }
}
