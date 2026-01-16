//
//  HistoryView.swift
//  Life247
//
//  Created by Andrew Robertson on 1/14/26.
//

import SwiftUI
import SwiftData

/// List of completed drives and inferred stops in a unified timeline.
struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Drive> { $0.endTime != nil },
           sort: \Drive.startTime,
           order: .reverse)
    private var drives: [Drive]
    
    @Query(sort: \Place.name)
    private var places: [Place]
    
    @State private var timeline: [TimelineItem] = []
    @State private var groupedTimeline: [(key: Date, value: [TimelineItem])] = []
    @State private var frequentStops: FrequentStopAnalysisResult = .empty
    @State private var displayLimit: Int = 10
    @State private var isLoading = true
    private let pageSize: Int = 5
    
    /// Whether there are more items to load
    private var hasMore: Bool {
        displayLimit < timeline.count
    }
    
    /// Visible grouped items (paginated)
    private var visibleGroupedItems: [(key: Date, value: [TimelineItem])] {
        // Calculate how many items we've shown
        var itemCount = 0
        var result: [(key: Date, value: [TimelineItem])] = []
        
        for group in groupedTimeline {
            if itemCount >= displayLimit { break }
            
            let remainingSlots = displayLimit - itemCount
            let itemsToTake = min(group.value.count, remainingSlots)
            
            if itemsToTake > 0 {
                result.append((key: group.key, value: Array(group.value.prefix(itemsToTake))))
                itemCount += itemsToTake
            }
        }
        
        return result
    }
    
    var body: some View {
        Group {
            if drives.isEmpty {
                EmptyHistoryView()
            } else {
                timelineList
            }
        }
        .navigationTitle("History")
        .onAppear {
            if timeline.isEmpty {
                Task { await rebuildTimeline() }
            }
        }
        .onChange(of: drives.count) { _, _ in
            Task { await rebuildTimeline() }
        }
        .onChange(of: places.count) { _, _ in
            Task { await rebuildTimeline() }
        }
    }
    
    private var timelineList: some View {
        List {
            ForEach(visibleGroupedItems, id: \.key) { date, items in
                Section {
                    ForEach(items) { item in
                        timelineRow(for: item)
                    }
                } header: {
                    Text(date, style: .date)
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
            }
            
            // Load More button
            if hasMore {
                Section {
                    Button(action: loadMore) {
                        HStack {
                            Spacer()
                            Text("Load More (\(timeline.count - displayLimit) remaining)")
                                .foregroundStyle(.blue)
                            Spacer()
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.bottom, 180, for: .scrollContent)
    }
    
    @ViewBuilder
    private func timelineRow(for item: TimelineItem) -> some View {
        switch item {
        case .drive(let drive):
            NavigationLink(destination: DriveDetailView(drive: drive)) {
                DriveRowView(drive: drive)
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    modelContext.delete(drive)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            
        case .stop(let stop):
            let frequentInfo = frequentStops.stopToCandidate[stop.id]
            NavigationLink(destination: StopDetailView(stop: stop, frequentStopInfo: frequentInfo)) {
                StopRowView(
                    stop: stop,
                    frequentStopInfo: frequentStops.stopToCandidate[stop.id]
                )
            }
        }
    }
    
    private func loadMore() {
        displayLimit += pageSize
    }
    
    private func rebuildTimeline() async {
        // Snapshot inputs (value semantics)
        let drivesSnapshot = drives
        let placesSnapshot = places
        
        // Do heavy work off main actor
        let result = await Task.detached(priority: .userInitiated) {
            // Build timeline
            let timeline = await TimelineBuilder.buildTimeline(
                drives: drivesSnapshot,
                places: placesSnapshot
            )
            
            // Extract stops for analysis
            let stops = timeline.compactMap { item -> InferredStop? in
                if case .stop(let stop) = item { return stop }
                return nil
            }
            
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
            
            return (timeline, frequent, sortedGroups)
        }.value
        
        // Single UI commit on main actor
        await MainActor.run {
            self.timeline = result.0
            self.frequentStops = result.1
            self.groupedTimeline = result.2
            self.isLoading = false
        }
    }
}

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

// MARK: - Drive Row

struct DriveRowView: View {
    let drive: Drive
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Type label
            HStack {
                Text("DRIVE")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundStyle(.blue)
                Spacer()
            }
            
            // Mini map (static snapshot)
            if drive.points.count > 1 {
                MiniRouteMap(drive: drive, height: 160)
            }
            
            // Stats row - balanced 4-column layout
            HStack(spacing: 16) {
                // Start time
                statItem(value: drive.startTime.formatted(date: .omitted, time: .shortened), label: "Time")
                
                // Duration
                statItem(value: drive.formattedDuration, label: "Duration")
                
                // Distance
                statItem(value: drive.formattedDistance, label: "Distance")
                
                // Max speed
                statItem(value: String(format: "%.0f", drive.maxSpeedMPH), label: "Max mph")
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 4)
    }
    
    private func statItem(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
                .monospacedDigit()
            
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    HistoryView()
        .modelContainer(for: [Drive.self, Place.self], inMemory: true)
}
