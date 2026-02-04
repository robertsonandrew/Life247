//
//  CalmDriveCard.swift
//  Life247
//
//  Created by Andrew Robertson on 1/23/26.
//

import SwiftUI
import SwiftData
import MapKit
import UIKit

/// A calm, scannable drive card with collapsible detail.
/// Collapsed: Route trace silhouette + location + time + key metrics
/// Expanded: Full map preview + secondary stats + CTA
struct CalmDriveCard: View {
    let drive: Drive
    let trace: [(coordinate: CLLocationCoordinate2D, speedMPH: Double)]
    let maxSpeedMPH: Double  // Pre-computed to avoid main-thread relationship fetch
    var destinationName: String? = nil
    var stopSummaryText: String? = nil
    var stopCanSavePlace: Bool = false
    @Binding var isExpanded: Bool

    @AppStorage("showSpeedTrace") private var showSpeedTrace = true
    
    /// Callback when user taps "View trip details"
    var onViewDetails: (() -> Void)?
    /// Callback for inline stop save action
    var onSaveStop: (() -> Void)?
    
    /// Callback for 5-tap inspector gesture
    var onInspector: (() -> Void)?
    
    /// Context menu actions
    var onShare: (() -> Void)?
    var onDelete: (() -> Void)?
    var onViewLogs: (() -> Void)?
    
    @Query private var places: [Place]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Always visible: collapsed content
            collapsedContent
            
            // Conditionally visible: expanded content
            // if isExpanded {
            //     expandedContent
            //         .transition(.opacity.combined(with: .move(edge: .top)))
            // }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        .contentShape(Rectangle())
        .onTapGesture {
            // withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            //     isExpanded.toggle()
            // }
            // Direct Sheet Navigation
            onViewDetails?()
        }
        .onTapGesture(count: 5) {
            onInspector?()
        }
        .contextMenu {
            Button {
                onShare?()
            } label: {
                Label("Share Drive", systemImage: "square.and.arrow.up")
            }
            
            Button {
                onViewLogs?()
            } label: {
                Label("View Logs", systemImage: "doc.text.magnifyingglass")
            }
            
            Divider()
            
            Button(role: .destructive) {
                onDelete?()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .task {
            guard destinationName == nil else { return }
            await drive.fetchNeighborhoodsIfNeeded()
        }
    }
    
    // MARK: - Collapsed Content
    
    private var collapsedContent: some View {
        HStack(alignment: .center, spacing: 12) {
            // Text content (left side)
            VStack(alignment: .leading, spacing: 4) {
                // Location label
                HStack(spacing: 8) {
                    Text(driveTitle)
                        .font(.headline)
                        .lineLimit(1)
                }
                
                // Time range + duration
                timeRow

                if let stopSummaryText {
                    Text(stopSummaryText)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.orange)
                    
                    if stopCanSavePlace {
                        Button {
                            onSaveStop?()
                        } label: {
                            Label("Save place", systemImage: "plus.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                    }
                }
                
                // Distance + max speed
                metricsRow
            }
            .layoutPriority(1)
            
            Spacer(minLength: 0)
            
            // Route trace (right side, fills the gap)
            routeTraceWide
            
            // Chevron
            // chevron
        }
    }
    
    /// Wide horizontal route trace that fills the right-side gap
    private var routeTraceWide: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemGray6))
            
            if trace.count >= 2 {
                let colorProvider: (Double) -> Color = { speed in
                    if showSpeedTrace {
                        return speedColor(for: speed)
                    }
                    return solidTraceColor
                }
                SpeedRouteTraceView(
                    tracePoints: trace,
                    speedColor: colorProvider,
                    lineWidth: 2.5
                )
                .padding(6)
            } else {
                // Fallback for drives with insufficient points
                Image(systemName: "car.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 120)
        .frame(height: 44)
    }

    private var timeRow: some View {
        HStack(spacing: 4) {
            Text(drive.startTime.formatted(date: .omitted, time: .shortened))
            Text("→")
                .foregroundStyle(.tertiary)
            Text(drive.endTime?.formatted(date: .omitted, time: .shortened) ?? "--:--")
            Text("·")
                .foregroundStyle(.tertiary)
            Text(drive.formattedDuration)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    
    private var metricsRow: some View {
        HStack(spacing: 4) {
            Text(drive.formattedDistance)
            Text("·")
                .foregroundStyle(.tertiary)
            Text("\(Int(maxSpeedMPH)) mph max")
                .foregroundStyle(speedColor(for: maxSpeedMPH))
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    /// Color-code speed based on road type thresholds
    private func speedColor(for speedMPH: Double) -> Color {
        switch speedMPH {
        case ..<25:
            return .green       // Residential/Slow
        case 25..<45:
            return .yellow      // Arterial
        case 45..<65:
            return .orange      // Highway
        default:
            return .red         // Interstate
        }
    }

    private var solidTraceColor: Color {
        .blue
    }
    
    private var chevron: some View {
        Image(systemName: "chevron.down")
            .font(.footnote)
            .fontWeight(.semibold)
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(isExpanded ? 180 : 0))
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
            .padding(.top, 2)
    }
    
    // MARK: - Expanded Content
    
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Divider
            Rectangle()
                .fill(Color(.separator))
                .frame(height: 0.5)
                .padding(.top, 12)
            
            // Map preview
            mapPreview
            
            // Secondary metrics
            secondaryMetrics
            
            // CTA
            viewDetailsButton
        }
    }
    
    private var mapPreview: some View {
        GeometryReader { geometry in
            MapSnapshotView(
                drive: drive,
                width: geometry.size.width,
                height: 180
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(height: 180)
    }
    
    private var secondaryMetrics: some View {
        HStack(spacing: 12) {
            if drive.averageSpeedMPH > 0 {
                Label("Avg \(Int(drive.averageSpeedMPH)) mph", systemImage: "gauge.medium")
            }
            
            // Show motion source info if available
            if let startReason = drive.startReason {
                Label(startReason.rawValue, systemImage: "location.fill")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var driveTitle: String {
        if let destination = destinationName {
            return "Drive to \(destination)"
        }
        if let endArea = drive.endNeighborhood {
            if let startArea = drive.startNeighborhood, startArea == endArea {
                return "Drive to \(endArea) area"
            }
            return "Drive to \(endArea)"
        }
        return drive.dynamicTitle
    }
    
    private var viewDetailsButton: some View {
        Button {
            onViewDetails?()
        } label: {
            HStack {
                Text("View trip details")
                Image(systemName: "chevron.right")
                    .font(.caption)
            }
            .font(.subheadline)
            .foregroundStyle(.blue)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview {
    struct PreviewWrapper: View {
        @State private var expanded1 = false
        @State private var expanded2 = true
        
        var body: some View {
            ScrollView {
                VStack(spacing: 12) {
                    // Drive with varying speeds
                    let trace1: [(CLLocationCoordinate2D, Double)] = [
                        (CLLocationCoordinate2D(latitude: 36.0, longitude: -95.9), 20),   // Green
                        (CLLocationCoordinate2D(latitude: 36.01, longitude: -95.88), 30), // Yellow
                        (CLLocationCoordinate2D(latitude: 36.02, longitude: -95.85), 50), // Orange
                        (CLLocationCoordinate2D(latitude: 36.03, longitude: -95.82), 70), // Red
                        (CLLocationCoordinate2D(latitude: 36.04, longitude: -95.8), 40)   // Yellow
                    ]
                    CalmDriveCard(
                        drive: Drive(), 
                        trace: trace1, 
                        maxSpeedMPH: 70, 
                        destinationName: "Multi-Speed Test", 
                        isExpanded: $expanded1
                    )
                    
                    // Fast drive
                    CalmDriveCard(
                        drive: Drive(), 
                        trace: [], 
                        maxSpeedMPH: 62, 
                        destinationName: nil, 
                        isExpanded: $expanded2
                    )
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
        }
    }
    
    return PreviewWrapper()
        .modelContainer(for: [Drive.self, Place.self], inMemory: true)
}
