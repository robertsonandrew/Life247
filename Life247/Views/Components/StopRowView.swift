//
//  StopRowView.swift
//  Life247
//
//  Created by Andrew Robertson on 1/15/26.
//

import SwiftUI
import CoreLocation

/// Ultra-slim "connector" row for stops in the timeline.
/// Two-column layout: Location left, duration right. Time window as subtitle.
/// No header - the timeline rail icon indicates it's a stop.
struct StopRowView: View {
    let stop: InferredStop
    let frequentStopInfo: FrequentStopCandidate?
    var onSavePlace: (() -> Void)? = nil

    
    /// Lazily loaded address (only fetched when view appears)
    @State private var lazyAddress: String?
    @State private var isLoadingAddress = false
    
    init(
        stop: InferredStop,
        frequentStopInfo: FrequentStopCandidate? = nil,
        onSavePlace: (() -> Void)? = nil
    ) {
        self.stop = stop
        self.frequentStopInfo = frequentStopInfo
        self.onSavePlace = onSavePlace
    }
    
    /// Display name: place name > pre-fetched address > lazy address > "Stopped"
    private var displayName: String {
        if let place = stop.matchedPlace {
            return place.name
        }
        if let address = stop.address {
            return address
        }
        if let lazy = lazyAddress {
            return lazy
        }
        return isLoadingAddress ? "Loading..." : "Stopped"
    }
    
    private var markerColor: Color {
        frequentStopInfo != nil ? .purple : .orange
    }

    private var shouldShowSaveAction: Bool {
        stop.matchedPlace == nil && frequentStopInfo == nil && onSavePlace != nil
    }
    
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // Left side: Location name + time window
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(frequentStopInfo != nil && stop.matchedPlace == nil ? "Frequent Stop" : displayName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    
                    // Frequent visit badge (compact)
                    if let frequent = frequentStopInfo {
                        Text(frequent.visitLabel)
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.purple)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(.purple.opacity(0.12))
                            )
                    }
                }
                
                Text(stop.timeRangeString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            
            Spacer(minLength: 8)
            
            // Right side: Duration + save action
            HStack(spacing: 8) {
                if shouldShowSaveAction, let onSavePlace {
                    Button(action: onSavePlace) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                }
                
                Text(stop.formattedDuration)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(markerColor)
                    .monospacedDigit()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(markerColor.opacity(0.12))
                    )
            }
        }
        .frame(maxWidth: 320, alignment: .leading)
        .padding(.vertical, 6)
        .task(id: stop.id) {
            await loadAddressIfNeeded()
        }
    }
    
    /// Lazy load address only when needed
    @MainActor
    private func loadAddressIfNeeded() async {
        // Skip if we already have a place or address
        guard stop.matchedPlace == nil, stop.address == nil, lazyAddress == nil else { return }
        
        isLoadingAddress = true
        lazyAddress = await GeocodingCache.shared.address(for: stop.location)
        isLoadingAddress = false
    }
}

#Preview {
    List {
        StopRowView(stop: InferredStop(
            id: UUID(),
            location: .init(latitude: 36.0, longitude: -95.9),
            startTime: Date().addingTimeInterval(-3600),
            endTime: Date().addingTimeInterval(-3000),
            matchedPlace: nil,
            address: "Dollar General"
        ))
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .listRowSeparator(.hidden)
        
        StopRowView(
            stop: InferredStop(
                id: UUID(),
                location: .init(latitude: 36.0, longitude: -95.9),
                startTime: Date().addingTimeInterval(-7200),
                endTime: Date().addingTimeInterval(-3600),
                matchedPlace: nil,
                address: "Home"
            ),
            frequentStopInfo: FrequentStopCandidate(
                coordinate: .init(latitude: 36.0, longitude: -95.9),
                visitCount: 5,
                totalDuration: 3600,
                lastVisited: Date()
            )
        )

        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .listRowSeparator(.hidden)
    }
    .listStyle(.plain)
}
