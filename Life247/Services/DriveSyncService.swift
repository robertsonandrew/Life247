//
//  DriveSyncService.swift
//  Life247
//
//  Created by Andrew Robertson on 1/17/26.
//

import Foundation
import SwiftUI
import SwiftData
import Combine
import Network

/// Service for syncing completed drives to a self-hosted server
/// Handles queue management, encoding, and background uploads
@MainActor
class DriveSyncService: ObservableObject {
    
    // MARK: - Configuration (stored in UserDefaults)
    
    @AppStorage("syncEnabled") var syncEnabled: Bool = false
    @AppStorage("syncServerURL") var serverURL: String = ""
    @AppStorage("syncAPIKey") var apiKey: String = ""
    @AppStorage("syncOnWiFiOnly") var syncOnWiFiOnly: Bool = true
    
    // MARK: - State
    
    @Published var pendingCount: Int = 0
    @Published var lastSyncDate: Date?
    @Published var lastError: String?
    @Published var isSyncing: Bool = false
    @Published var connectionTested: Bool = false
    @Published var connectionSuccess: Bool = false
    
    // Progress tracking for bulk sync
    @Published var syncProgress: (current: Int, total: Int)?
    
    // Network monitoring
    private let networkMonitor = NWPathMonitor()
    private var isOnWiFi: Bool = false
    
    /// Pending drive IDs (persisted)
    private var pendingDriveIds: [String] {
        get { UserDefaults.standard.stringArray(forKey: "pendingDriveIds") ?? [] }
        set {
            UserDefaults.standard.set(newValue, forKey: "pendingDriveIds")
            updatePendingCount()
        }
    }

    /// Pending place visit IDs (persisted)
    private var pendingPlaceVisitIds: [String] {
        get { UserDefaults.standard.stringArray(forKey: "pendingPlaceVisitIds") ?? [] }
        set {
            UserDefaults.standard.set(newValue, forKey: "pendingPlaceVisitIds")
            updatePendingCount()
        }
    }
    
    /// Retry counts for failed items (persisted)
    private var retryCountsKey = "syncRetryCounts"
    private var retryCounts: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: retryCountsKey) as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: retryCountsKey) }
    }
    
    /// Maximum retry attempts before giving up
    private let maxRetryCount = 5
    
    /// Backoff multiplier (seconds) - retry delay = 2^retryCount * baseBackoff
    private let baseBackoffSeconds: Double = 30
    
    private var hasStarted = false
    private var cancellables = Set<AnyCancellable>()
    private var modelContainer: ModelContainer?
    
    init() {
        // Start network monitoring
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let usesWiFi = path.usesInterfaceType(.wifi)
            Task { @MainActor [weak self] in
                self?.isOnWiFi = usesWiFi
            }
        }
        networkMonitor.start(queue: DispatchQueue.global(qos: .utility))
    }
    
    deinit {
        networkMonitor.cancel()
    }
    
    private func updatePendingCount() {
        pendingCount = pendingDriveIds.count + pendingPlaceVisitIds.count
    }
    
    /// Explicit startup - call once from app root
    func start(container: ModelContainer) {
        guard !hasStarted else { return }
        hasStarted = true
        self.modelContainer = container
        updatePendingCount()
        
        // Listen for new finished drives
        NotificationCenter.default.publisher(for: .driveEnded)
            .compactMap { $0.userInfo?[NotificationKeys.driveId] as? String }
            .receive(on: RunLoop.main)
            .sink { [weak self] driveId in
                self?.queueDriveById(driveId)
            }
            .store(in: &cancellables)

        // Listen for closed place visits
        NotificationCenter.default.publisher(for: .placeVisitEnded)
            .compactMap { $0.userInfo?[NotificationKeys.placeVisitId] as? String }
            .receive(on: RunLoop.main)
            .sink { [weak self] visitId in
                self?.queuePlaceVisitById(visitId)
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Network Check
    
    /// Check if sync is allowed based on network conditions
    private func canSync() -> Bool {
        if syncOnWiFiOnly && !isOnWiFi {
            lastError = "Waiting for WiFi connection"
            return false
        }
        return true
    }
    
    // MARK: - Retry Logic
    
    private func shouldRetry(_ itemId: String) -> Bool {
        let count = retryCounts[itemId] ?? 0
        return count < maxRetryCount
    }
    
    private func incrementRetryCount(_ itemId: String) {
        var counts = retryCounts
        counts[itemId] = (counts[itemId] ?? 0) + 1
        retryCounts = counts
    }
    
    private func clearRetryCount(_ itemId: String) {
        var counts = retryCounts
        counts.removeValue(forKey: itemId)
        retryCounts = counts
    }
    
    private func backoffDelay(for itemId: String) -> TimeInterval {
        let count = retryCounts[itemId] ?? 0
        return pow(2.0, Double(count)) * baseBackoffSeconds
    }
    
    // MARK: - Public API
    
    /// Queue a completed drive for upload
    func queueDrive(_ drive: Drive) {
        queueDriveById(drive.id.uuidString)
    }

    /// Queue a completed place visit for upload
    func queuePlaceVisit(_ visit: PlaceVisit) {
        queuePlaceVisitById(visit.id.uuidString)
    }
    
    /// Internal helper to queue by ID string (does NOT auto-sync; user must trigger manually)
    private func queueDriveById(_ driveIdString: String) {
        guard syncEnabled else { return }
        guard !pendingDriveIds.contains(driveIdString) else { return }
        
        var ids = pendingDriveIds
        ids.append(driveIdString)
        pendingDriveIds = ids
    }

    private func queuePlaceVisitById(_ visitIdString: String) {
        guard syncEnabled else { return }
        guard !pendingPlaceVisitIds.contains(visitIdString) else { return }

        var ids = pendingPlaceVisitIds
        ids.append(visitIdString)
        pendingPlaceVisitIds = ids
    }

    /// Sync everything pending (drives + place visits)
    func syncPending(modelContext: ModelContext?) async {
        guard syncEnabled, !serverURL.isEmpty else { return }
        guard !isSyncing else { return }
        guard !pendingDriveIds.isEmpty || !pendingPlaceVisitIds.isEmpty else { return }
        guard canSync() else { return }

        isSyncing = true
        lastError = nil
        defer { 
            isSyncing = false 
            syncProgress = nil
        }

        guard let context = modelContext ?? modelContainer?.mainContext else {
            lastError = "No model context available"
            return
        }

        await syncPendingDrivesInternal(modelContext: context)
        await syncPendingPlaceVisitsInternal(modelContext: context)
    }
    
    /// Sync all pending drives (legacy, calls syncPending)
    func syncPendingDrives(modelContext: ModelContext?) async {
        await syncPending(modelContext: modelContext)
    }

    private func syncPendingDrivesInternal(modelContext context: ModelContext) async {
        // Take a snapshot of IDs to process
        let idsToProcess = pendingDriveIds
        guard !idsToProcess.isEmpty else { return }
        
        let total = idsToProcess.count + pendingPlaceVisitIds.count
        var processed = 0

        for driveIdString in idsToProcess {
            // Check retry eligibility
            if !shouldRetry(driveIdString) {
                removeDriveFromQueue(driveIdString)
                continue
            }
            
            guard let driveId = UUID(uuidString: driveIdString) else {
                removeDriveFromQueue(driveIdString)
                continue
            }
            
            // Fetch the drive
            let descriptor = FetchDescriptor<Drive>(
                predicate: #Predicate { $0.id == driveId }
            )
            
            guard let drive = try? context.fetch(descriptor).first else {
                // Drive no longer exists, remove from queue
                removeDriveFromQueue(driveIdString)
                clearRetryCount(driveIdString)
                continue
            }
            
            // Skip if already synced
            if drive.syncStatus == "synced" {
                removeDriveFromQueue(driveIdString)
                clearRetryCount(driveIdString)
                continue
            }
            
            // Upload the drive
            let success = await uploadDrive(drive)
            
            processed += 1
            syncProgress = (processed, total)
            
            if success {
                drive.syncedAt = Date()
                drive.syncStatus = "synced"
                removeDriveFromQueue(driveIdString)
                clearRetryCount(driveIdString)
                lastSyncDate = Date()
                
                try? context.save()
            } else {
                drive.syncStatus = "failed"
                incrementRetryCount(driveIdString)
                try? context.save()
            }
        }
    }

    private func syncPendingPlaceVisitsInternal(modelContext context: ModelContext) async {
        // Take a snapshot of IDs to process
        let idsToProcess = pendingPlaceVisitIds
        guard !idsToProcess.isEmpty else { return }
        
        let driveCount = pendingDriveIds.count
        let total = driveCount + idsToProcess.count
        var processed = driveCount // Start from where drives left off

        for visitIdString in idsToProcess {
            // Check retry eligibility
            if !shouldRetry(visitIdString) {
                removePlaceVisitFromQueue(visitIdString)
                continue
            }
            
            guard let visitId = UUID(uuidString: visitIdString) else {
                removePlaceVisitFromQueue(visitIdString)
                continue
            }

            let descriptor = FetchDescriptor<PlaceVisit>(
                predicate: #Predicate { $0.id == visitId }
            )

            guard let visit = try? context.fetch(descriptor).first else {
                removePlaceVisitFromQueue(visitIdString)
                clearRetryCount(visitIdString)
                continue
            }

            // Only sync completed visits
            guard visit.departureTime != nil else {
                continue
            }

            if visit.syncStatus == "synced" {
                removePlaceVisitFromQueue(visitIdString)
                clearRetryCount(visitIdString)
                continue
            }

            let success = await uploadPlaceVisit(visit)
            
            processed += 1
            syncProgress = (processed, total)
            
            if success {
                visit.syncedAt = Date()
                visit.syncStatus = "synced"
                removePlaceVisitFromQueue(visitIdString)
                clearRetryCount(visitIdString)
                lastSyncDate = Date()
                try? context.save()
            } else {
                visit.syncStatus = "failed"
                incrementRetryCount(visitIdString)
                try? context.save()
            }
        }
    }
    
    /// Check if a drive has been synced
    func isSynced(_ driveId: UUID) -> Bool {
        !pendingDriveIds.contains(driveId.uuidString)
    }
    
    /// Manually retry failed syncs
    func retryFailed() async {
        guard let context = modelContainer?.mainContext else {
            lastError = "No model context available"
            return
        }
        await syncPending(modelContext: context)
    }
    
    /// Clear all pending items (use with caution)
    func clearQueue() {
        pendingDriveIds = []
        pendingPlaceVisitIds = []
        retryCounts = [:]
    }
    
    // MARK: - Sync All (Unified)
    
    /// Queue ALL unsynced items (drives + place visits) for sync
    func syncAll(modelContext: ModelContext) async {
        guard syncEnabled, !serverURL.isEmpty else {
            lastError = "Sync not configured"
            return
        }
        guard canSync() else { return }
        
        // Queue all unsynced drives
        await queueAllUnsyncedDrives(modelContext: modelContext)
        
        // Queue all unsynced place visits
        await queueAllUnsyncedPlaceVisits(modelContext: modelContext)
        
        // Now sync everything
        await syncPending(modelContext: modelContext)
    }
    
    /// Queue ALL completed drives for sync (useful for initial sync)
    func syncAllDrives(modelContext: ModelContext) async {
        guard syncEnabled, !serverURL.isEmpty else {
            lastError = "Sync not configured"
            return
        }
        guard canSync() else { return }
        
        await queueAllUnsyncedDrives(modelContext: modelContext)
        await syncPending(modelContext: modelContext)
    }
    
    /// Queue ALL completed place visits for sync
    func syncAllPlaceVisits(modelContext: ModelContext) async {
        guard syncEnabled, !serverURL.isEmpty else {
            lastError = "Sync not configured"
            return
        }
        guard canSync() else { return }
        
        await queueAllUnsyncedPlaceVisits(modelContext: modelContext)
        await syncPending(modelContext: modelContext)
    }
    
    private func queueAllUnsyncedDrives(modelContext: ModelContext) async {
        let descriptor = FetchDescriptor<Drive>(
            predicate: #Predicate { $0.endTime != nil }
        )
        
        guard let drives = try? modelContext.fetch(descriptor) else {
            lastError = "Failed to fetch drives"
            return
        }
        
        let unsynced = drives.filter { $0.syncStatus != "synced" }
        
        if unsynced.isEmpty {
            return
        }
        
        var ids = pendingDriveIds
        for drive in unsynced {
            let idString = drive.id.uuidString
            if !ids.contains(idString) {
                ids.append(idString)
                drive.syncStatus = "pending"
            }
        }
        pendingDriveIds = ids
        try? modelContext.save()
    }
    
    private func queueAllUnsyncedPlaceVisits(modelContext: ModelContext) async {
        let descriptor = FetchDescriptor<PlaceVisit>(
            predicate: #Predicate { $0.departureTime != nil }
        )
        
        guard let visits = try? modelContext.fetch(descriptor) else {
            lastError = "Failed to fetch place visits"
            return
        }
        
        let unsynced = visits.filter { $0.syncStatus != "synced" }
        
        if unsynced.isEmpty {
            return
        }
        
        var ids = pendingPlaceVisitIds
        for visit in unsynced {
            let idString = visit.id.uuidString
            if !ids.contains(idString) {
                ids.append(idString)
                visit.syncStatus = "pending"
            }
        }
        pendingPlaceVisitIds = ids
        try? modelContext.save()
    }
    
    /// Reset sync status of ALL items to pending (force re-sync)
    func resetAllSyncStatus(modelContext: ModelContext) async {
        // Reset drives
        let driveDescriptor = FetchDescriptor<Drive>()
        if let drives = try? modelContext.fetch(driveDescriptor) {
            for drive in drives {
                drive.syncStatus = "pending"
            }
        }
        
        // Reset place visits
        let visitDescriptor = FetchDescriptor<PlaceVisit>()
        if let visits = try? modelContext.fetch(visitDescriptor) {
            for visit in visits {
                visit.syncStatus = "pending"
            }
        }
        
        try? modelContext.save()
        
        // Clear queues and retry counts, then rebuild
        pendingDriveIds = []
        pendingPlaceVisitIds = []
        retryCounts = [:]
        
        await syncAll(modelContext: modelContext)
    }
    
    /// Test connection to the server
    func testConnection() async -> Bool {
        connectionTested = false
        
        guard !serverURL.isEmpty else {
            lastError = "Server URL is empty"
            connectionTested = true
            connectionSuccess = false
            return false
        }
        
        guard let url = URL(string: "\(serverURL)/health") else {
            lastError = "Invalid server URL"
            connectionTested = true
            connectionSuccess = false
            return false
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.timeoutInterval = 10
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                lastError = "Invalid response"
                connectionTested = true
                connectionSuccess = false
                return false
            }
            
            if httpResponse.statusCode == 200 {
                lastError = nil
                connectionTested = true
                connectionSuccess = true
                return true
            } else if httpResponse.statusCode == 401 {
                lastError = "Unauthorized - check API key"
                connectionTested = true
                connectionSuccess = false
                return false
            } else {
                lastError = "Server error: \(httpResponse.statusCode)"
                connectionTested = true
                connectionSuccess = false
                return false
            }
        } catch let error as URLError {
            if error.code == .cannotConnectToHost {
                lastError = "Cannot connect to server"
            } else if error.code == .timedOut {
                lastError = "Connection timed out"
            } else {
                lastError = "Network error: \(error.localizedDescription)"
            }
            connectionTested = true
            connectionSuccess = false
            return false
        } catch {
            lastError = "Error: \(error.localizedDescription)"
            connectionTested = true
            connectionSuccess = false
            return false
        }
    }
    
    // MARK: - Private Methods
    
    private func removeDriveFromQueue(_ driveIdString: String) {
        var ids = pendingDriveIds
        ids.removeAll { $0 == driveIdString }
        pendingDriveIds = ids
    }

    private func removePlaceVisitFromQueue(_ visitIdString: String) {
        var ids = pendingPlaceVisitIds
        ids.removeAll { $0 == visitIdString }
        pendingPlaceVisitIds = ids
    }
    
    private func uploadDrive(_ drive: Drive) async -> Bool {
        // Create DTO with encoded polyline
        let dto = DriveUploadDTO(from: drive)
        
        guard let url = URL(string: "\(serverURL)/drives") else {
            lastError = "Invalid server URL"
            return false
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.timeoutInterval = 30
        
        do {
            request.httpBody = try dto.toJSONData()
        } catch {
            lastError = "Failed to encode drive: \(error.localizedDescription)"
            return false
        }
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                lastError = "Invalid response"
                return false
            }
            
            if httpResponse.statusCode == 200 || httpResponse.statusCode == 201 {
                return true
            } else if httpResponse.statusCode == 401 {
                lastError = "Unauthorized - check API key"
                return false
            } else {
                lastError = "Server error: \(httpResponse.statusCode)"
                return false
            }
        } catch {
            lastError = "Network error: \(error.localizedDescription)"
            return false
        }
    }

    private func uploadPlaceVisit(_ visit: PlaceVisit) async -> Bool {
        let dto = PlaceVisitUploadDTO(from: visit)

        guard let url = URL(string: "\(serverURL)/visits") else {
            lastError = "Invalid server URL"
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.timeoutInterval = 30

        do {
            request.httpBody = try dto.toJSONData()
        } catch {
            lastError = "Failed to encode visit: \(error.localizedDescription)"
            return false
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                lastError = "Invalid response"
                return false
            }

            if httpResponse.statusCode == 200 || httpResponse.statusCode == 201 {
                return true
            } else if httpResponse.statusCode == 401 {
                lastError = "Unauthorized - check API key"
                return false
            } else {
                lastError = "Server error: \(httpResponse.statusCode)"
                return false
            }
        } catch {
            lastError = "Network error: \(error.localizedDescription)"
            return false
        }
    }
    
    // MARK: - Place Sync (Push on Change)
    
    /// Sync a single place to the server (upsert)
    /// Call this when a place is created or updated
    func syncPlace(_ place: Place) async {
        guard syncEnabled, !serverURL.isEmpty, !apiKey.isEmpty else { return }
        guard canSync() else { return }
        
        let dto = PlaceUploadDTO(from: place, deviceId: deviceId)
        
        guard let url = URL(string: "\(serverURL)/places/sync") else {
            lastError = "Invalid server URL"
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.timeoutInterval = 15
        
        do {
            let encoder = JSONEncoder()
            request.httpBody = try encoder.encode(dto)
        } catch {
            lastError = "Failed to encode place: \(error.localizedDescription)"
            return
        }
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                lastError = "Invalid response"
                return
            }
            
            if httpResponse.statusCode == 200 || httpResponse.statusCode == 201 {
                // Success - place synced
                lastError = nil
            } else if httpResponse.statusCode == 401 {
                lastError = "Unauthorized - check API key"
            } else {
                lastError = "Server error: \(httpResponse.statusCode)"
            }
        } catch {
            lastError = "Network error: \(error.localizedDescription)"
        }
    }
    
    /// Delete a place from the server
    /// Call this when a place is deleted locally
    func deletePlace(_ placeId: UUID) async {
        guard syncEnabled, !serverURL.isEmpty, !apiKey.isEmpty else { return }
        guard canSync() else { return }
        
        guard let url = URL(string: "\(serverURL)/places/\(placeId.uuidString)") else {
            lastError = "Invalid server URL"
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.addValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.timeoutInterval = 15
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                lastError = "Invalid response"
                return
            }
            
            if httpResponse.statusCode == 200 || httpResponse.statusCode == 404 {
                // Success (404 = already deleted, which is fine)
                lastError = nil
            } else if httpResponse.statusCode == 401 {
                lastError = "Unauthorized - check API key"
            } else {
                lastError = "Server error: \(httpResponse.statusCode)"
            }
        } catch {
            lastError = "Network error: \(error.localizedDescription)"
        }
    }
    
    /// Sync all places to the server (bulk push)
    /// Useful for initial sync or recovery
    func syncAllPlaces(modelContext: ModelContext) async {
        guard syncEnabled, !serverURL.isEmpty else {
            lastError = "Sync not configured"
            return
        }
        guard canSync() else { return }
        
        let descriptor = FetchDescriptor<Place>()
        guard let places = try? modelContext.fetch(descriptor) else {
            lastError = "Failed to fetch places"
            return
        }
        
        for place in places {
            await syncPlace(place)
            // Small delay between requests
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
    }
    
    /// Device identifier for place sync
    private var deviceId: String {
        UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
    }
}

// MARK: - Sync Status Extension

extension Drive {
    /// Formatted sync status for display
    var syncStatusDisplay: String {
        switch syncStatus {
        case "synced":
            if let date = syncedAt {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .abbreviated
                return "Synced \(formatter.localizedString(for: date, relativeTo: Date()))"
            }
            return "Synced"
        case "pending":
            return "Pending sync"
        case "failed":
            return "Sync failed"
        default:
            return "Not synced"
        }
    }
    
    /// Whether this drive needs to be synced
    var needsSync: Bool {
        syncStatus != "synced" && endTime != nil
    }
}
