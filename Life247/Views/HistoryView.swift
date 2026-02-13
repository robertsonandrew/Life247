//
//  HistoryView.swift
//  Life247
//
//  Created by Andrew Robertson on 1/14/26.
//

import SwiftUI
import SwiftData
import MapKit

/// List of completed drives and inferred stops in a unified timeline.
struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Drive> { $0.endTime != nil },
           sort: \Drive.startTime,
           order: .reverse)
    private var drives: [Drive]
    
    @Query(sort: \Place.name)
    private var places: [Place]
    
    @AppStorage("feature.history.tripGrouping.enabled")
    private var tripGroupingEnabled = true
    
    @State private var timeline: [TimelineItem] = []
    @State private var groupedTimeline: [(key: Date, value: [TimelineItem])] = []
    @State private var daySummaries: [Date: DaySummary] = [:]
    @State private var frequentStops: FrequentStopAnalysisResult = .empty
    @State private var driveLimit: Int = 20
    @State private var isLoading = true
    @State private var isLoadingMore = false
    private let drivePageSize: Int = 10
    
    // Deletion confirmation state
    @State private var driveToDelete: Drive?
    @State private var showDeleteConfirmation = false
    
    // Debug inspector state (lifted from DriveRowView to avoid lazy container issue)
    @State private var inspectorDrive: Drive?
    
    // Direct logs sheet state (for View Logs context menu action)
    @State private var logsDrive: Drive?
    @State private var logsSelectedCategory: LogCategory? = nil
    
    // Programmatic navigation state
    @State private var selectedDrive: Drive?
    
    // Track which drive cards are expanded (most recent pre-expanded)
    @State private var expandedDriveIDs: Set<UUID> = []
    @State private var expandedTripIDs: Set<UUID> = []
    @State private var hasInitializedExpansion = false
    
    // Sharing state
    @State private var shareItems: [Any]?
    @State private var isSharing = false
    @State private var isGeneratingShare = false
    @State private var placeSaveRequest: PlaceSaveRequest?
    
    /// Whether there are more items to load
    private var hasMore: Bool {
        driveLimit < drives.count
    }

    /// Visible grouped items (paginated, pre-computed in rebuildTimeline)
    @State private var visibleGroupedItems: [(key: Date, value: [TimelineItem])] = []
    
    var body: some View {
        Group {
            if drives.isEmpty {
                EmptyHistoryView()
            } else {
                timelineList
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if timeline.isEmpty {
                Task { await rebuildTimeline() }
            }
        }
        .onChange(of: drives.count) { _, _ in
            scheduleRebuild()
        }
        .onChange(of: places.count) { _, _ in
            scheduleRebuild()
        }
        .onChange(of: tripGroupingEnabled) { _, _ in
            scheduleRebuild()
        }

        .navigationDestination(item: $inspectorDrive) { drive in
            DriveInspectorView(drive: drive)
        }
        .sheet(item: $selectedDrive) { drive in
            NavigationStack {
                DriveDetailView(drive: drive)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") {
                                selectedDrive = nil
                            }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(.regularMaterial)
        }
        .confirmationDialog(
            "Delete Drive?",
            isPresented: $showDeleteConfirmation, 
            titleVisibility: .visible
        ) {
            Button("Delete Drive", role: .destructive) {
                if let drive = driveToDelete {
                    // Delete from context
                    modelContext.delete(drive)
                    // Rebuild will trigger automatically via onChange
                }
            }
            Button("Cancel", role: .cancel) {
                driveToDelete = nil
            }
        } message: {
            Text("This action cannot be undone.")
        }
        .sheet(isPresented: $isSharing) {
            if let items = shareItems {
                ShareSheet(activityItems: items)
                    .presentationDetents([.medium, .large])
            }
        }
        .sheet(item: $logsDrive) { drive in
            TimelineSheetView(
                entries: drive.logEntriesChronological,
                selectedCategory: $logsSelectedCategory
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $placeSaveRequest) { request in
            NavigationStack {
                SaveAsPlaceView(coordinate: request.coordinate)
            }
        }
    }
    
    // MARK: - Debounced Rebuild
    
    /// Pending rebuild task (cancelled on new changes)
    @State private var rebuildTask: Task<Void, Never>?
    
    /// Debounce rapid changes - wait 300ms before rebuilding
    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms
            guard !Task.isCancelled else { return }
            await rebuildTimeline()
        }
    }
    
    private var timelineList: some View {
        List {
            ForEach(visibleGroupedItems, id: \.key) { date, items in
                let (displayItems, stopSummaries) = mergeStops(in: items)
                Section {
                    ForEach(Array(displayItems.enumerated()), id: \.element.id) { index, item in
                        let isFirst = index == 0
                        let isLast = index == displayItems.count - 1
                        let showDivider = index > 0 && displayItems[index - 1].isStop != item.isStop
                        let stopSummaryText: String? = {
                            if case .drive(let drive, _, _, _) = item {
                                return stopSummaries[drive.id]?.summaryText
                            }
                            return nil
                        }()
                        let stopCanSavePlace: Bool = {
                            if case .drive(let drive, _, _, _) = item {
                                return stopSummaries[drive.id]?.canSavePlace ?? false
                            }
                            return false
                        }()
                        let stopSaveAction: (() -> Void)? = {
                            if case .drive(let drive, _, _, _) = item,
                               let summary = stopSummaries[drive.id],
                               summary.canSavePlace {
                                return { placeSaveRequest = PlaceSaveRequest(coordinate: summary.coordinate) }
                            }
                            return nil
                        }()

                        VStack(spacing: 8) {
                            if showDivider {
                                Rectangle()
                                    .fill(Color.white.opacity(0.08))
                                    .frame(height: 1)
                                    .padding(.vertical, 2)
                            }
                            timelineRow(
                                for: item,
                                isFirst: isFirst,
                                isLast: isLast,
                                stopSummaryText: stopSummaryText,
                                stopCanSavePlace: stopCanSavePlace,
                                onSaveStop: stopSaveAction
                            )
                        }
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                } header: {
                    DayHeaderView(
                        date: date,
                        summary: daySummaries[date]
                    )
                }
                .textCase(nil)
            }
            
            if hasMore && !isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .onAppear { loadMore() }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
        .bottomBarPadding()
    }


    
    @ViewBuilder
    private func timelineRow(
        for item: TimelineItem,
        isFirst: Bool,
        isLast: Bool,
        stopSummaryText: String? = nil,
        stopCanSavePlace: Bool = false,
        onSaveStop: (() -> Void)? = nil
    ) -> some View {
        switch item {
        case .drive(let drive, let trace, let maxSpeedMPH, let destinationName):
            driveRow(
                drive: drive,
                trace: trace,
                maxSpeedMPH: maxSpeedMPH,
                destinationName: destinationName,
                stopSummaryText: stopSummaryText,
                stopCanSavePlace: stopCanSavePlace,
                onSaveStop: onSaveStop
            )

            
        case .stop(let stop):
            stopRow(for: stop)

        case .trip(let trip):
            let isExpanded = expandedTripIDs.contains(trip.id)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(trip.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(tripTimeSummary(for: trip))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(tripMetricsSummary(for: trip))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    Button {
                        toggleTripExpansion(trip.id)
                    } label: {
                        Image(systemName: expandedTripIDs.contains(trip.id) ? "chevron.up.circle.fill" : "chevron.down.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                if isExpanded {
                    let (tripItems, tripStopSummaries) = mergeStops(in: trip.items)
                    VStack(spacing: 8) {
                        ForEach(Array(tripItems.enumerated()), id: \.element.id) { index, childItem in
                            let childStopSummaryText: String? = {
                                if case .drive(let drive, _, _, _) = childItem {
                                    return tripStopSummaries[drive.id]?.summaryText
                                }
                                return nil
                            }()
                            let childCanSavePlace: Bool = {
                                if case .drive(let drive, _, _, _) = childItem {
                                    return tripStopSummaries[drive.id]?.canSavePlace ?? false
                                }
                                return false
                            }()
                            let childSaveAction: (() -> Void)? = {
                                if case .drive(let drive, _, _, _) = childItem,
                                   let summary = tripStopSummaries[drive.id],
                                   summary.canSavePlace {
                                    return { placeSaveRequest = PlaceSaveRequest(coordinate: summary.coordinate) }
                                }
                                return nil
                            }()

                            switch childItem {
                            case .drive(let drive, let trace, let maxSpeedMPH, let destinationName):
                                driveRow(
                                    drive: drive,
                                    trace: trace,
                                    maxSpeedMPH: maxSpeedMPH,
                                    destinationName: destinationName,
                                    stopSummaryText: childStopSummaryText,
                                    stopCanSavePlace: childCanSavePlace,
                                    onSaveStop: childSaveAction
                                )
                            case .stop(let stop):
                                stopRow(for: stop)
                            case .trip:
                                EmptyView()
                            }
                        }
                    }
                    .padding(.leading, 8)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onTapGesture {
                guard !isExpanded else { return }
                toggleTripExpansion(trip.id)
            }
        }
    }

    private func driveRow(
        drive: Drive,
        trace: [(coordinate: CLLocationCoordinate2D, speedMPH: Double)],
        maxSpeedMPH: Double,
        destinationName: String?,
        stopSummaryText: String?,
        stopCanSavePlace: Bool,
        onSaveStop: (() -> Void)?
    ) -> some View {
        CalmDriveCard(
            drive: drive,
            trace: trace,
            maxSpeedMPH: maxSpeedMPH,
            destinationName: destinationName,
            stopSummaryText: stopSummaryText,
            stopCanSavePlace: stopCanSavePlace,
            isExpanded: Binding(
                get: { expandedDriveIDs.contains(drive.id) },
                set: { newValue in
                    if newValue {
                        expandedDriveIDs.insert(drive.id)
                    } else {
                        expandedDriveIDs.remove(drive.id)
                    }
                }
            ),
            onViewDetails: { selectedDrive = drive },
            onSaveStop: onSaveStop,
            onInspector: { inspectorDrive = drive },
            onShare: {
                Task { await generateShareImage(for: drive) }
            },
            onDelete: {
                driveToDelete = drive
                showDeleteConfirmation = true
            },
            onViewLogs: { logsDrive = drive }
        )
    }

    @ViewBuilder
    private func stopRow(for stop: InferredStop) -> some View {
        let frequentInfo = frequentStops.stopToCandidate[stop.id]
        if stop.matchedPlace == nil, let frequentInfo {
            SuggestedPlaceRowView(
                candidate: frequentInfo,
                durationText: stop.formattedDuration,
                onAdd: {
                    placeSaveRequest = PlaceSaveRequest(coordinate: frequentInfo.coordinate)
                }
            )
        } else {
            NavigationLink(destination: StopDetailView(stop: stop, frequentStopInfo: frequentInfo)) {
                StopRowView(
                    stop: stop,
                    frequentStopInfo: frequentInfo,
                    onSavePlace: stop.matchedPlace == nil
                        ? { placeSaveRequest = PlaceSaveRequest(coordinate: stop.location) }
                        : nil
                )
            }
        }
    }

    private func toggleTripExpansion(_ tripID: UUID) {
        if expandedTripIDs.contains(tripID) {
            expandedTripIDs.remove(tripID)
        } else {
            expandedTripIDs.insert(tripID)
        }
    }

    private func tripTimeSummary(for trip: TripGroup) -> String {
        "\(trip.startTime.formatted(date: .omitted, time: .shortened)) → \(trip.endTime.formatted(date: .omitted, time: .shortened)) · \(trip.formattedTotalDuration)"
    }

    private func tripMetricsSummary(for trip: TripGroup) -> String {
        "\(trip.driveCount) drive\(trip.driveCount == 1 ? "" : "s") · \(trip.stopCount) stop\(trip.stopCount == 1 ? "" : "s") · \(trip.formattedDistance)"
    }

    private func mergeStops(in items: [TimelineItem]) -> ([TimelineItem], [UUID: StopSummary]) {
        var result: [TimelineItem] = []
        var stopSummaries: [UUID: StopSummary] = [:]

        var index = 0
        while index < items.count {
            let item = items[index]
            if case .stop(let stop) = item,
               stop.source == .betweenDrives,
               index + 1 < items.count,
               case .drive(let drive, _, _, _) = items[index + 1] {
                if stopSummaries[drive.id] == nil {
                    stopSummaries[drive.id] = buildStopSummary(from: stop)
                }
                index += 1
                continue
            }

            if case .drive(let drive, _, _, _) = item,
               index + 1 < items.count,
               case .stop(let stop) = items[index + 1],
               stop.source == .inDriveGap {
                if stopSummaries[drive.id] == nil {
                    stopSummaries[drive.id] = buildStopSummary(from: stop)
                }
                result.append(item)
                index += 2
                continue
            }
            result.append(item)
            index += 1
        }

        return (result, stopSummaries)
    }

    private func buildStopSummary(from stop: InferredStop) -> StopSummary {
        let stopName = stop.displayName
        let canSavePlace = stop.matchedPlace == nil
        if stopName != "Stopped" {
            return StopSummary(
                summaryText: "Stop · \(stopName) · \(stop.formattedDuration)",
                coordinate: stop.location,
                canSavePlace: canSavePlace
            )
        } else {
            return StopSummary(
                summaryText: "Stop · \(stop.formattedDuration)",
                coordinate: stop.location,
                canSavePlace: canSavePlace
            )
        }
    }

    private struct StopSummary {
        let summaryText: String
        let coordinate: CLLocationCoordinate2D
        let canSavePlace: Bool
    }
    
    private func loadMore() {
        guard hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        driveLimit += drivePageSize
        scheduleRebuild()
    }
    
    private func rebuildTimeline() async {
        // Snapshot inputs (value semantics)
        let drivesSnapshot = drives
        let placesSnapshot = places
        let currentLimit = driveLimit + drivePageSize  // Build slightly ahead for smooth pagination

        // SwiftData models are MainActor-isolated under Swift 6 strict concurrency.
        // Keep this work on the current actor to avoid cross-actor violations.
        let result = await Task(priority: .userInitiated) {
            // Build timeline (only for visible drives + buffer)
            let timeline = await TimelineBuilder.buildTimeline(
                drives: drivesSnapshot,
                places: placesSnapshot,
                tripGroupingEnabled: tripGroupingEnabled,
                limit: currentLimit
            )
            
            // Extract stops for analysis
            let stops = Self.extractStops(from: timeline)
            
            // Analyze frequent stops
            let frequent = FrequentStopAnalyzer.analyze(
                stops: stops,
                places: placesSnapshot
            )
            
            // Pre-compute grouped timeline
            let calendar = Calendar.current
            let grouped = Dictionary(grouping: timeline) { item in
                calendar.startOfDay(for: item.startTime)
            }
            let sortedGroups = grouped.sorted { $0.key > $1.key }
                .map { (key: $0.key, value: $0.value) }

            // Pre-compute day summaries (full-day counts, not paginated)
            var summaries: [Date: DaySummary] = [:]
            for (day, dayItems) in grouped {
                let driveCount = dayItems.reduce(into: 0) { acc, item in
                    acc += Self.driveCount(for: item)
                }
                let stopCount = dayItems.reduce(into: 0) { acc, item in
                    acc += Self.stopCount(for: item)
                }
                summaries[day] = DaySummary(drives: driveCount, stops: stopCount)
            }
            
            return (timeline, frequent, sortedGroups, summaries)
        }.value
        
        // Single UI commit on main actor
        await MainActor.run {
            self.timeline = result.0
            self.frequentStops = result.1
            self.groupedTimeline = result.2
            self.daySummaries = result.3
            self.visibleGroupedItems = Self.paginateGroups(result.2, limit: driveLimit)
            let visibleTripIDs = Set(result.0.compactMap { item -> UUID? in
                if case .trip(let trip) = item {
                    return trip.id
                }
                return nil
            })
            self.expandedTripIDs = self.expandedTripIDs.intersection(visibleTripIDs)
            self.isLoading = false
            self.isLoadingMore = false
        }
    }
    
    /// Paginate grouped timeline by drive count.
    private nonisolated static func paginateGroups(
        _ groups: [(key: Date, value: [TimelineItem])],
        limit: Int
    ) -> [(key: Date, value: [TimelineItem])] {
        var visibleDriveCount = 0
        var result: [(key: Date, value: [TimelineItem])] = []

        for group in groups {
            if visibleDriveCount >= limit { break }
            var groupItems: [TimelineItem] = []
            for item in group.value {
                if visibleDriveCount >= limit { break }
                groupItems.append(item)
                visibleDriveCount += driveCount(for: item)
            }
            if !groupItems.isEmpty {
                result.append((key: group.key, value: groupItems))
            }
        }
        return result
    }

    private nonisolated static func driveCount(for item: TimelineItem) -> Int {
        switch item {
        case .drive:
            return 1
        case .stop:
            return 0
        case .trip(let trip):
            return trip.items.reduce(into: 0) { acc, child in
                acc += driveCount(for: child)
            }
        }
    }

    private nonisolated static func stopCount(for item: TimelineItem) -> Int {
        switch item {
        case .drive:
            return 0
        case .stop:
            return 1
        case .trip(let trip):
            return trip.items.reduce(into: 0) { acc, child in
                acc += stopCount(for: child)
            }
        }
    }

    private nonisolated static func extractStops(from items: [TimelineItem]) -> [InferredStop] {
        items.flatMap(extractStops(from:))
    }

    private nonisolated static func extractStops(from item: TimelineItem) -> [InferredStop] {
        switch item {
        case .stop(let stop):
            return [stop]
        case .trip(let trip):
            return extractStops(from: trip.items)
        case .drive:
            return []
        }
    }

    @MainActor
    private func generateShareImage(for drive: Drive) async {
        isGeneratingShare = true
        defer { isGeneratingShare = false }
        
        // 1. Configure options
        let options = MKMapSnapshotter.Options()
        if let bounds = drive.routeBounds {
            options.region = MKCoordinateRegion(center: bounds.center, span: bounds.span)
        }
        options.size = CGSize(width: 600, height: 400)
        let displayScale = UITraitCollection.current.displayScale
        options.traitCollection = UITraitCollection(mutations: { traits in
            traits.userInterfaceStyle = .dark
            traits.displayScale = displayScale
        })
        
        // 2. Take snapshot
        let snapshotter = MKMapSnapshotter(options: options)
        do {
            let snapshot = try await snapshotter.start()
            
            // 3. Draw route
            let renderer = UIGraphicsImageRenderer(size: options.size)
            let image = renderer.image { context in
                // Draw map
                snapshot.image.draw(at: .zero)
                
                // Draw route trace
                let points = drive.pointsChronological.map { snapshot.point(for: $0.coordinate) }
                if points.count > 1 {
                    let path = UIBezierPath()
                    path.move(to: points[0])
                    for point in points.dropFirst() {
                        path.addLine(to: point)
                    }
                    
                    // Gradient-like stroke (simplified as solid for share)
                    UIColor.systemBlue.setStroke()
                    path.lineWidth = 4
                    path.lineCapStyle = .round
                    path.lineJoinStyle = .round
                    path.stroke()
                }
                
                // Draw title overlay
                let title = "Drive: \(drive.formattedDistance)"
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 20, weight: .bold),
                    .foregroundColor: UIColor.white
                ]
                let str = NSAttributedString(string: title, attributes: attrs)
                str.draw(at: CGPoint(x: 20, y: 20))
            }
            
            self.shareItems = [image, "Check out my drive!"]
            self.isSharing = true
        } catch {
            print("Failed to generate snapshot: \(error)")
        }
    }
}

// MARK: - Day Header

private struct DaySummary: Sendable {
    let drives: Int
    let stops: Int
}

private struct DayHeaderView: View {
    let date: Date
    let summary: DaySummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(date, style: .date)
                .font(.headline)
                .foregroundStyle(.primary)

            if let summary {
                Text("\(summary.drives) drive\(summary.drives == 1 ? "" : "s") • \(summary.stops) stop\(summary.stops == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

private struct PlaceSaveRequest: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
}

// MARK: - Timeline Connector

/// Wraps a timeline item with a vertical connector line to show chronological flow
// MARK: - Timeline Connector

/// Wraps a timeline item with a vertical connector line (Solid Subway Style)

// MARK: - Empty State

struct EmptyHistoryView: View {
    var body: some View {
        ContentUnavailableView(
            "No Drives Yet",
            systemImage: "car.fill",
            description: Text("Your completed drives will appear here")
        )
    }
}

#Preview {
    HistoryView()
        .modelContainer(for: [Drive.self, Place.self], inMemory: true)
}

// MARK: - Share Sheet (Moved to Shared Component)
