//
//  DriveInspectorView.swift
//  Life247
//
//  Created by Andrew Robertson on 1/16/26.
//

import SwiftUI
import SwiftData

/// Debug Drive Inspector - shows raw samples, derived metrics, lifecycle events, and anomalies.
/// Entry: 5-tap gesture on drive duration in History view.
struct DriveInspectorView: View {
    let drive: Drive
    
    @State private var selectedCategory: LogCategory? = nil
    @State private var showTimelineSheet = false
    @State private var showingShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var cachedExportText: String?
    @State private var cachedExportJSONL: String?
    @State private var isGeneratingExport = false
    
    private var filteredEntries: [DriveLogEntry] {
        let chronological = drive.logEntriesChronological
        guard let category = selectedCategory else { return chronological }
        return chronological.filter { $0.category == category }
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summarySection
                systemContextSection
                timelineSection
            }
            .padding()
        }
        .bottomBarPadding()
        .navigationTitle("🔍 Drive Inspector")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isGeneratingExport {
                    ProgressView()
                        .progressViewStyle(.circular)
                } else {
                    Button {
                        Task { await prepareShareExport() }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            if !shareItems.isEmpty {
                ShareSheet(activityItems: shareItems)
            }
        }
        .sheet(isPresented: $showTimelineSheet) {
            TimelineSheetView(
                entries: filteredEntries,
                selectedCategory: $selectedCategory
            )
        }
        .task {
            // Pre-generate both human report and machine-readable JSONL.
            async let reportText = generateExportTextAsync()
            async let reportJSONL = generateExportJSONLAsync()
            cachedExportText = await reportText
            cachedExportJSONL = await reportJSONL
        }
    }

    
    // MARK: - Summary Section
    
    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("SUMMARY")
            
            VStack(spacing: 8) {
                HStack {
                    summaryItem(label: "Duration", value: drive.formattedDuration)
                    Spacer()
                    summaryItem(label: "Distance", value: drive.formattedDistance)
                }
                
                HStack {
                    summaryItem(label: "Avg Speed", value: String(format: "%.0f mph", drive.averageSpeedMPH))
                    Spacer()
                    summaryItem(label: "Max Speed", value: String(format: "%.0f mph", drive.maxSpeedMPH))
                }
                
                Divider()
                
                HStack {
                    if let latency = drive.detectionLatency {
                        summaryItem(label: "Detection Latency", value: String(format: "%.1fs", latency))
                    }
                    Spacer()
                    if let confirmLatency = drive.confirmationLatency {
                        summaryItem(label: "Confirm Latency", value: String(format: "%.1fs", confirmLatency))
                    }
                }
                
                HStack {
                    summaryItem(label: "Samples", value: "\(drive.locationSampleCount)")
                    Spacer()
                    summaryItem(label: "Dropped", value: "\(drive.droppedSampleCount)")
                    Spacer()
                    summaryItem(label: "GPS Pauses", value: "\(drive.locationPauseCount)")
                }
                
                if drive.maxGapBetweenSamples > 0 {
                    HStack {
                        summaryItem(label: "Max Gap", value: String(format: "%.0fs", drive.maxGapBetweenSamples))
                        Spacer()
                    }
                }

                if drive.distanceGapSkipCount > 0 {
                    HStack {
                        summaryItem(label: "Gap Skips", value: "\(drive.distanceGapSkipCount)")
                        Spacer()
                        summaryItem(label: "Skipped Dist", value: String(format: "%.2f mi", drive.distanceGapSkippedMeters / 1609.344))
                    }
                }
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(12)
        }
    }
    
    // MARK: - System Context Section
    
    private var systemContextSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("SYSTEM CONTEXT")
            
            VStack(spacing: 8) {
                HStack {
                    Text("iOS")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(drive.iosVersion ?? "Unknown")
                        .fontWeight(.medium)
                }
                
                HStack {
                    Text("Device")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(deviceName(for: drive.deviceModel))
                        .fontWeight(.medium)
                }
                
                HStack {
                    Text("App Version")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(drive.appVersion ?? "Unknown")
                        .fontWeight(.medium)
                }
                
                Divider()
                
                HStack {
                    Text("Battery")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(batteryString)
                        .fontWeight(.medium)
                }
                
                HStack {
                    Text("Start Reason")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(drive.startReason?.rawValue ?? "Unknown")
                        .fontWeight(.medium)
                        .foregroundStyle(.purple)
                }
                
                HStack {
                    Text("End Reason")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(drive.endReason?.rawValue ?? "Unknown")
                        .fontWeight(.medium)
                        .foregroundStyle(.orange)
                }
                
                if drive.lowPowerModeAtStart == true {
                    HStack {
                        Image(systemName: "battery.25")
                            .foregroundStyle(.yellow)
                        Text("Low Power Mode was ON")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(12)
        }
    }
    
    // MARK: - Timeline Section (Sheet-based)
    
    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    showTimelineSheet = true
                } label: {
                    HStack {
                        sectionHeader("TIMELINE (\(filteredEntries.count))")
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                
                Spacer()
                categoryFilterMenu
            }
            
            // Preview of recent events
            VStack(alignment: .leading, spacing: 8) {
                if filteredEntries.isEmpty {
                    Text("No events recorded")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    // Show last 3 events as preview
                    ForEach(filteredEntries.suffix(3).reversed(), id: \.id) { entry in
                        HStack(spacing: 8) {
                            Text(entry.formattedTime)
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Text(entry.category.emoji)
                            Text(entry.message)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                        }
                    }
                    
                    Button {
                        showTimelineSheet = true
                    } label: {
                        Text("View all \(filteredEntries.count) events →")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 4)
                }
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(12)
        }
    }
    
    private var categoryFilterMenu: some View {
        Menu {
            Button("All") { selectedCategory = nil }
            Divider()
            ForEach(LogCategory.allCases, id: \.self) { category in
                Button {
                    selectedCategory = category
                } label: {
                    Label(category.label, systemImage: categoryIcon(for: category))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedCategory?.label ?? "All")
                    .font(.caption)
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .foregroundStyle(.blue)
        }
    }
    
    // MARK: - Export

    private struct JSONLTimelineEvent: Codable {
        let schemaVersion: Int
        let driveId: String
        let driveShortId: String
        let seq: Int
        let eventId: String
        let timestamp: String
        let relativeSeconds: Double
        let category: String
        let eventType: String
        let message: String
        let reasonCode: String
        let stateFrom: String?
        let stateTo: String?
        let trigger: String?
        let appState: String?
        let accM: Double?
        let speedMph: Double?
        let locAgeS: Double?
        let gapS: Double?
        let metadata: [String: String]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case driveId = "drive_id"
            case driveShortId = "drive_short_id"
            case seq
            case eventId = "event_id"
            case timestamp
            case relativeSeconds = "relative_seconds"
            case category
            case eventType = "event_type"
            case message
            case reasonCode = "reason_code"
            case stateFrom = "state_from"
            case stateTo = "state_to"
            case trigger
            case appState = "app_state"
            case accM = "acc_m"
            case speedMph = "speed_mph"
            case locAgeS = "loc_age_s"
            case gapS = "gap_s"
            case metadata
        }
    }

    @MainActor
    private func prepareShareExport() async {
        isGeneratingExport = true
        defer { isGeneratingExport = false }

        let reportText: String
        if let cachedExportText {
            reportText = cachedExportText
        } else {
            let generated = await generateExportTextAsync()
            cachedExportText = generated
            reportText = generated
        }

        let reportJSONL: String
        if let cachedExportJSONL {
            reportJSONL = cachedExportJSONL
        } else {
            let generated = await generateExportJSONLAsync()
            cachedExportJSONL = generated
            reportJSONL = generated
        }

        shareItems = writeShareItems(reportText: reportText, reportJSONL: reportJSONL)
        showingShareSheet = true
    }

    private func writeShareItems(reportText: String, reportJSONL: String) -> [Any] {
        let tempDir = FileManager.default.temporaryDirectory
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let baseName = "drive_\(drive.shortId)_\(timestamp)"
        let textURL = tempDir.appendingPathComponent("\(baseName).txt")
        let jsonlURL = tempDir.appendingPathComponent("\(baseName).jsonl")

        do {
            try reportText.write(to: textURL, atomically: true, encoding: .utf8)
            try reportJSONL.write(to: jsonlURL, atomically: true, encoding: .utf8)
            return [textURL, jsonlURL]
        } catch {
            // Fallback keeps sharing functional even if temp file writes fail.
            return [reportText, reportJSONL]
        }
    }

    /// Async text report generation for background pre-computation.
    private func generateExportTextAsync() async -> String {
        // Capture necessary values before going off main thread
        let driveShortId = drive.shortId
        let startTime = drive.startTime
        let endTime = drive.endTime
        let formattedDuration = drive.formattedDuration
        let formattedDistance = drive.formattedDistance
        let averageSpeedMPH = drive.averageSpeedMPH
        let maxSpeedMPH = drive.maxSpeedMPH
        let detectionLatency = drive.detectionLatency
        let confirmationLatency = drive.confirmationLatency
        let locationSampleCount = drive.locationSampleCount
        let droppedSampleCount = drive.droppedSampleCount
        let locationPauseCount = drive.locationPauseCount
        let maxGapBetweenSamples = drive.maxGapBetweenSamples
        let distanceGapSkipCount = drive.distanceGapSkipCount
        let distanceGapSkippedMiles = drive.distanceGapSkippedMeters / 1609.344
        let iosVersion = drive.iosVersion
        let deviceModel = drive.deviceModel
        let appVersion = drive.appVersion
        let batteryStr = batteryString
        let startReason = drive.startReason?.rawValue
        let endReason = drive.endReason?.rawValue
        let lowPowerMode = drive.lowPowerModeAtStart
        let chronologicalEntries = drive.logEntriesChronological.enumerated().map { index, entry -> (index: Int, seq: Int, time: String, category: String, eventType: String, message: String, metadata: [String: String]?) in
            (
                index: index + 1,
                seq: entry.sequenceNumber ?? 0,
                time: entry.formattedTime,
                category: entry.category.label,
                eventType: entry.eventType,
                message: entry.message,
                metadata: entry.metadata
            )
        }
        let deviceNameStr = deviceName(for: deviceModel)
        
        return await Task.detached(priority: .userInitiated) {
            var lines: [String] = []
            lines.reserveCapacity(chronologicalEntries.count + 50)
            
            lines.append("═══════════════════════════════════════")
            lines.append("DRIVE INSPECTOR REPORT")
            lines.append("Generated: \(Date().formatted())")
            lines.append("═══════════════════════════════════════")
            lines.append("")
            
            // Drive ID
            lines.append("Drive ID: \(driveShortId)")
            lines.append("Start: \(startTime.formatted())")
            if let endTime {
                lines.append("End: \(endTime.formatted())")
            }
            lines.append("")
            
            // Summary
            lines.append("─── SUMMARY ───")
            lines.append("Duration: \(formattedDuration)")
            lines.append("Distance: \(formattedDistance)")
            lines.append("Avg Speed: \(String(format: "%.0f mph", averageSpeedMPH))")
            lines.append("Max Speed: \(String(format: "%.0f mph", maxSpeedMPH))")
            if let latency = detectionLatency {
                lines.append("Detection Latency: \(String(format: "%.1fs", latency))")
            }
            if let confirmLatency = confirmationLatency {
                lines.append("Confirmation Latency: \(String(format: "%.1fs", confirmLatency))")
            }
            lines.append("Samples: \(locationSampleCount)")
            lines.append("Dropped: \(droppedSampleCount)")
            lines.append("GPS Pauses: \(locationPauseCount)")
            lines.append("Max Gap: \(String(format: "%.0fs", maxGapBetweenSamples))")
            lines.append("Gap Skips: \(distanceGapSkipCount)")
            lines.append("Skipped Distance: \(String(format: "%.2f mi", distanceGapSkippedMiles))")
            lines.append("")
            
            // System Context
            lines.append("─── SYSTEM CONTEXT ───")
            lines.append("iOS: \(iosVersion ?? "Unknown")")
            lines.append("Device: \(deviceNameStr)")
            lines.append("App Version: \(appVersion ?? "Unknown")")
            lines.append("Battery: \(batteryStr)")
            lines.append("Start Reason: \(startReason ?? "Unknown")")
            lines.append("End Reason: \(endReason ?? "Unknown")")
            if lowPowerMode == true {
                lines.append("⚠️ Low Power Mode was ON")
            }
            lines.append("")
            
            // Timeline
            lines.append("─── TIMELINE (\(chronologicalEntries.count) events) ───")
            for entry in chronologicalEntries {
                let eventSeq = entry.seq > 0 ? entry.seq : entry.index
                lines.append("\(entry.time) #\(eventSeq) [\(entry.category)] \(entry.message) | type: \(entry.eventType)")
                if let metadata = entry.metadata {
                    for (key, value) in metadata.sorted(by: { $0.key < $1.key }) {
                        lines.append("    \(key): \(value)")
                    }
                }
            }
            
            lines.append("")
            lines.append("═══════════════════════════════════════")
            lines.append("END OF REPORT")
            lines.append("═══════════════════════════════════════")
            
            return lines.joined(separator: "\n")
        }.value
    }

    /// Async JSON Lines export with normalized high-signal fields.
    private func generateExportJSONLAsync() async -> String {
        let driveId = drive.id.uuidString
        let driveShortId = drive.shortId
        let driveStartTime = drive.startTime
        let entries = drive.logEntriesChronological.enumerated().map { index, entry in
            (
                index: index + 1,
                seq: entry.sequenceNumber ?? 0,
                eventId: entry.id.uuidString,
                timestamp: entry.timestamp,
                category: entry.category.rawValue,
                eventType: entry.eventType,
                message: entry.message,
                metadata: entry.metadata ?? [:]
            )
        }

        return await Task.detached(priority: .userInitiated) {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]

            var lines: [String] = []
            lines.reserveCapacity(entries.count)

            for entry in entries {
                let meta = entry.metadata
                let seq = entry.seq > 0 ? entry.seq : entry.index
                let reasonCode = Self.firstValue(
                    for: ["reason_code", "reason", "rule", "input_startReason", "input_endReason"],
                    in: meta
                ) ?? entry.eventType

                let exportEvent = JSONLTimelineEvent(
                    schemaVersion: 1,
                    driveId: driveId,
                    driveShortId: driveShortId,
                    seq: seq,
                    eventId: entry.eventId,
                    timestamp: iso.string(from: entry.timestamp),
                    relativeSeconds: max(0, entry.timestamp.timeIntervalSince(driveStartTime)),
                    category: entry.category,
                    eventType: entry.eventType,
                    message: entry.message,
                    reasonCode: reasonCode,
                    stateFrom: Self.firstValue(for: ["state_from", "fromState", "input_fromState"], in: meta),
                    stateTo: Self.firstValue(for: ["state_to", "toState", "input_toState"], in: meta),
                    trigger: Self.firstValue(for: ["trigger", "input_trigger"], in: meta),
                    appState: Self.firstValue(for: ["app_state", "appState", "state", "input_appState"], in: meta),
                    accM: Self.firstDouble(for: ["acc_m", "accuracyM", "accuracy"], in: meta),
                    speedMph: Self.firstDouble(for: ["speed_mph", "speedMPH", "speed", "input_speed"], in: meta),
                    locAgeS: Self.firstDouble(for: ["loc_age_s", "ageSeconds", "age"], in: meta),
                    gapS: Self.firstDouble(for: ["gap_s", "gapSeconds"], in: meta),
                    metadata: meta
                )

                if let data = try? encoder.encode(exportEvent),
                   let line = String(data: data, encoding: .utf8) {
                    lines.append(line)
                }
            }
            return lines.joined(separator: "\n")
        }.value
    }

    private static func firstValue(for keys: [String], in metadata: [String: String]) -> String? {
        for key in keys {
            if let value = metadata[key], !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func firstDouble(for keys: [String], in metadata: [String: String]) -> Double? {
        for key in keys {
            guard let raw = metadata[key], !raw.isEmpty else { continue }
            if let value = parseFirstDouble(raw) {
                return value
            }
        }
        return nil
    }

    private static func parseFirstDouble(_ raw: String) -> Double? {
        let tokens = raw.split { ch in
            !(ch.isNumber || ch == "." || ch == "-")
        }
        for token in tokens {
            if let value = Double(token) {
                return value
            }
        }
        return nil
    }
    
    // MARK: - Helpers
    
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
    }
    
    private func summaryItem(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
    }
    
    private var batteryString: String {
        let start = drive.batteryLevelAtStart.map { "\(Int($0 * 100))%" } ?? "?"
        let end = drive.batteryLevelAtEnd.map { "\(Int($0 * 100))%" } ?? "?"
        return "\(start) → \(end)"
    }
    
    private func categoryIcon(for category: LogCategory) -> String {
        switch category {
        case .system: return "gearshape"
        case .motion: return "figure.walk"
        case .location: return "location"
        case .decision: return "brain"
        case .anomaly: return "exclamationmark.triangle"
        case .trace: return "waveform.path.ecg"
        }
    }
    
    private func deviceName(for identifier: String?) -> String {
        // Common device identifiers
        guard let id = identifier else { return "Unknown" }
        let mapping: [String: String] = [
            "iPhone17,1": "iPhone 16 Pro",
            "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone16,1": "iPhone 15 Pro",
            "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone15,2": "iPhone 14 Pro",
            "iPhone15,3": "iPhone 14 Pro Max",
        ]
        return mapping[id] ?? id
    }
}

// MARK: - Timeline Sheet View

struct TimelineSheetView: View {
    let entries: [DriveLogEntry]
    @Binding var selectedCategory: LogCategory?
    @Environment(\.dismiss) private var dismiss
    @State private var expandedEntries: Set<UUID> = []
    @State private var isAllExpanded = false
    @State private var showCopiedAllFeedback = false
    
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(entries, id: \.id) { entry in
                        TimelineSheetRow(
                            entry: entry,
                            isExpanded: isAllExpanded || expandedEntries.contains(entry.id),
                            onToggleExpand: { toggleExpansion(entry.id) }
                        )
                        .id(entry.id)
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("Timeline (\(entries.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 12) {
                        categoryFilterMenuSheet
                        
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isAllExpanded.toggle()
                                if !isAllExpanded {
                                    expandedEntries.removeAll()
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: isAllExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                                Text(isAllExpanded ? "Collapse" : "Expand")
                            }
                            .font(.subheadline)
                            .foregroundStyle(.blue)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            copyAllFiltered()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: showCopiedAllFeedback ? "checkmark" : "doc.on.doc")
                                Text(showCopiedAllFeedback ? "Copied!" : "Copy All")
                            }
                            .font(.subheadline)
                            .foregroundStyle(showCopiedAllFeedback ? .green : .blue)
                        }
                        
                        Button("Done") {
                            dismiss()
                        }
                        .fontWeight(.semibold)
                    }
                }
            }
        }
    }
    
    private func toggleExpansion(_ id: UUID) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if expandedEntries.contains(id) {
                expandedEntries.remove(id)
            } else {
                expandedEntries.insert(id)
            }
        }
    }
    
    private var categoryFilterMenuSheet: some View {
        Menu {
            Button("All") { selectedCategory = nil }
            Divider()
            ForEach(LogCategory.allCases, id: \.self) { category in
                Button {
                    selectedCategory = category
                } label: {
                    Label(category.label, systemImage: categoryIcon(for: category))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedCategory?.label ?? "All")
                    .font(.subheadline)
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .foregroundStyle(.blue)
        }
    }
    
    private func categoryIcon(for category: LogCategory) -> String {
        switch category {
        case .system: return "gearshape"
        case .motion: return "figure.walk"
        case .location: return "location"
        case .decision: return "brain"
        case .anomaly: return "exclamationmark.triangle"
        case .trace: return "waveform.path.ecg"
        }
    }
    
    private func copyAllFiltered() {
        let lines = entries.enumerated().map { index, entry -> String in
            let seq = (entry.sequenceNumber ?? 0) > 0 ? (entry.sequenceNumber ?? 0) : index + 1
            var text = "[\(entry.formattedTime) #\(seq)] \(entry.category.emoji) \(entry.message) | type: \(entry.eventType)"
            if let metadata = entry.metadata {
                let metaStr = metadata.sorted(by: { $0.key < $1.key })
                    .map { "\($0.key): \($0.value)" }
                    .joined(separator: ", ")
                text += " | \(metaStr)"
            }
            return text
        }
        
        let filterLabel = selectedCategory?.label ?? "All"
        let header = "=== Timeline (\(filterLabel)) - \(entries.count) entries ===\n"
        UIPasteboard.general.string = header + lines.joined(separator: "\n")
        
        withAnimation {
            showCopiedAllFeedback = true
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation {
                showCopiedAllFeedback = false
            }
        }
    }
}

// MARK: - Timeline Sheet Row

struct TimelineSheetRow: View {
    let entry: DriveLogEntry
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    
    @State private var copiedValue: String?
    
    private var hasMetadata: Bool {
        entry.metadata != nil && !(entry.metadata?.isEmpty ?? true)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: Time + Category + Expand indicator
            HStack(spacing: 8) {
                Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                
                HStack(spacing: 4) {
                    Text(entry.category.emoji)
                    Text(entry.category.label)
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(categoryColor.opacity(0.15))
                .cornerRadius(4)

                if let sequenceNumber = entry.sequenceNumber, sequenceNumber > 0 {
                    Text("#\(sequenceNumber)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                if hasMetadata {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            
            // Message
            Text(entry.message)
                .font(.subheadline)
                .lineLimit(isExpanded ? nil : 2)
            
            // Metadata - only shown when expanded
            if isExpanded, let metadata = entry.metadata, !metadata.isEmpty {
                metadataChipsView(metadata)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if hasMetadata {
                onToggleExpand()
            }
        }
        .contextMenu {
            Button {
                copyEntryAsText()
            } label: {
                Label("Copy as Text", systemImage: "doc.on.doc")
            }
            
            Button {
                copyEntryAsJSON()
            } label: {
                Label("Copy as JSON", systemImage: "curlybraces")
            }
            
            if hasMetadata {
                Divider()
                Button {
                    onToggleExpand()
                } label: {
                    Label(isExpanded ? "Collapse" : "Expand Details", 
                          systemImage: isExpanded ? "chevron.up" : "chevron.down")
                }
            }
        }
    }
    
    // MARK: - Metadata Chips View
    
    @ViewBuilder
    private func metadataChipsView(_ metadata: [String: String]) -> some View {
        let sortedKeys = metadata.keys.sorted()
        let shortItems = sortedKeys.filter { key in
            let value = metadata[key] ?? ""
            return value.count <= 20 && !isLongIdentifier(value)
        }
        let longItems = sortedKeys.filter { key in
            let value = metadata[key] ?? ""
            return value.count > 20 || isLongIdentifier(value)
        }
        
        VStack(alignment: .leading, spacing: 8) {
            // Short values as horizontal chips
            if !shortItems.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(shortItems, id: \.self) { key in
                        metadataChip(key: key, value: metadata[key] ?? "")
                    }
                }
            }
            
            // Long values (UUIDs, etc.) as full-width rows
            if !longItems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(longItems, id: \.self) { key in
                        longValueRow(key: key, value: metadata[key] ?? "")
                    }
                }
            }
        }
        .padding(8)
        .background(Color(.systemGray6))
        .cornerRadius(6)
    }
    
    private func metadataChip(key: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(humanReadableKey(key))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(valueColor(for: value))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(.systemGray5))
        .cornerRadius(4)
        .onTapGesture {
            copyToClipboard(value)
        }
    }
    
    private func longValueRow(key: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(humanReadableKey(key))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            
            Text(isLongIdentifier(value) ? truncateValue(value, maxLength: 16) : value)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(copiedValue == value ? .green : .primary)
            
            Spacer()
            
            if isLongIdentifier(value) {
                Button {
                    copyToClipboard(value)
                } label: {
                    Image(systemName: copiedValue == value ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(copiedValue == value ? .green : .blue)
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    // MARK: - Copy Functions
    
    private func copyToClipboard(_ value: String) {
        UIPasteboard.general.string = value
        withAnimation {
            copiedValue = value
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation {
                if copiedValue == value {
                    copiedValue = nil
                }
            }
        }
    }
    
    private func copyEntryAsText() {
        let seq = (entry.sequenceNumber ?? 0) > 0 ? " #\(entry.sequenceNumber ?? 0)" : ""
        var text = "[\(entry.formattedTime)\(seq)] \(entry.category.emoji) \(entry.message) | type: \(entry.eventType)"
        if let metadata = entry.metadata, !metadata.isEmpty {
            let metaStr = metadata.sorted(by: { $0.key < $1.key })
                .map { "\(humanReadableKey($0.key)): \($0.value)" }
                .joined(separator: ", ")
            text += "\n  \(metaStr)"
        }
        UIPasteboard.general.string = text
    }
    
    private func copyEntryAsJSON() {
        let sequenceNumber = entry.sequenceNumber ?? 0
        var dict: [String: Any] = [
            "event_id": entry.id.uuidString,
            "seq": sequenceNumber,
            "timestamp": entry.timestamp.ISO8601Format(),
            "category": entry.category.rawValue,
            "event_type": entry.eventType,
            "message": entry.message
        ]
        if let metadata = entry.metadata {
            dict["metadata"] = metadata
        }
        
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            UIPasteboard.general.string = json
        }
    }
    
    // MARK: - Helpers
    
    private var categoryColor: Color {
        switch entry.category {
        case .system: return .gray
        case .motion: return .orange
        case .location: return .blue
        case .decision: return .purple
        case .anomaly: return .red
        case .trace: return .gray.opacity(0.7)
        }
    }
    
    private func valueColor(for value: String) -> Color {
        // Color-code certain value types for quick scanning
        let lowercased = value.lowercased()
        if lowercased == "true" || lowercased == "yes" || lowercased == "active" {
            return .green
        } else if lowercased == "false" || lowercased == "no" || lowercased == "inactive" {
            return .red
        } else if lowercased.contains("error") || lowercased.contains("fail") {
            return .red
        } else if lowercased == "background" {
            return .orange
        }
        return .primary
    }
}

// MARK: - Flow Layout for Chips

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .unspecified)
        }
    }
    
    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let maxWidth = proposal.width ?? .infinity
        var frames: [CGRect] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            
            frames.append(CGRect(origin: CGPoint(x: currentX, y: currentY), size: size))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
        }
        
        let totalHeight = currentY + lineHeight
        return (CGSize(width: maxWidth, height: totalHeight), frames)
    }
}

// MARK: - Timeline Event Row

struct TimelineEventRow: View {
    let entry: DriveLogEntry
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(entry.formattedTime)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                
                Text(entry.category.emoji)
                
                Text(entry.message)
                    .font(.subheadline)
                    .lineLimit(isExpanded ? nil : 1)
                
                Spacer()
                
                if entry.metadata != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if entry.metadata != nil {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }
            }
            
            if isExpanded, let metadata = entry.metadata {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(metadata.keys.sorted(), id: \.self) { key in
                        HStack(spacing: 4) {
                            Text(key + ":")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(metadata[key] ?? "")
                                .font(.caption2)
                                .fontWeight(.medium)
                        }
                    }
                }
                .padding(.leading, 50)
                .padding(.vertical, 4)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Share Sheet

// MARK: - Share Sheet (Moved to Shared Component)

// MARK: - Helpers

/// Truncates long strings (like UUIDs) to a readable length with ellipsis
private func truncateValue(_ value: String, maxLength: Int = 12) -> String {
    guard value.count > maxLength else { return value }
    return String(value.prefix(maxLength)) + "…"
}

/// Maps raw technical keys to human-readable labels
private func humanReadableKey(_ key: String) -> String {
    let mapping: [String: String] = [
        // Input keys
        "input_speed": "Speed",
        "input_start-Reason": "Start Reason",
        "input_end-Reason": "End Reason",
        "input_app-State": "App State",
        "input_battery": "Battery",
        "input_accuracy": "Accuracy",
        "input_confidence": "Confidence",
        "input_activity": "Activity",
        "input_latitude": "Latitude",
        "input_longitude": "Longitude",
        "input_heading": "Heading",
        "input_altitude": "Altitude",
        "input_timestamp": "Timestamp",
        
        // State keys
        "state_previous": "Previous State",
        "state_new": "New State",
        "state_duration": "State Duration",
        
        // Drive keys
        "drive_id": "Drive ID",
        "drive_distance": "Distance",
        "drive_duration": "Duration",
        "drive_samples": "Samples",
        
        // Decision keys
        "decision_threshold": "Threshold",
        "decision_timer": "Timer",
        "decision_result": "Result",
        
        // Common suffixes
        "_id": "ID",
        "_uuid": "UUID",
    ]
    
    // Direct match
    if let readable = mapping[key] {
        return readable
    }
    
    // Transform snake_case/kebab-case to Title Case
    let cleaned = key
        .replacingOccurrences(of: "input_", with: "")
        .replacingOccurrences(of: "state_", with: "")
        .replacingOccurrences(of: "drive_", with: "")
        .replacingOccurrences(of: "decision_", with: "")
        .replacingOccurrences(of: "-", with: " ")
        .replacingOccurrences(of: "_", with: " ")
    
    return cleaned.capitalized
}

/// Determines if a value looks like a UUID or long identifier
private func isLongIdentifier(_ value: String) -> Bool {
    // UUIDs are 36 chars with hyphens, or 32 without
    let uuidPattern = value.count >= 32 && value.contains(where: { $0.isHexDigit || $0 == "-" })
    return uuidPattern || value.count > 20
}

#Preview {
    NavigationStack {
        DriveInspectorView(drive: Drive())
    }
}
