//
//  NavigationBar.swift
//  Life247
//
//  Created by Andrew Robertson on 1/15/26.
//

import SwiftUI

/// Unified navigation + status bar.
/// - Status on top, tabs as footer (revealed by drag)
/// - Expansion controls visibility, DriveState controls content
/// - Drag works in both idle and driving states
struct NavigationBar: View {
    // Navigation (read-only via binding)
    @Binding var selectedTab: AppTab
    @Binding var isExpanded: Bool
    
    // Drive state (read-only)
    let driveState: DriveState
    let speed: Double
    let distance: Double
    let duration: TimeInterval
    let avgSpeed: Double
    let maxSpeed: Double
    let pointCount: Int
    let onEndDrive: (() -> Void)?
    
    // MARK: - Row Heights (Source of Truth)
    
    private let handleHeight: CGFloat = 16
    private let statusHeight: CGFloat = 44
    private let extraStatsHeight: CGFloat = 50
    private let tabsHeight: CGFloat = 56
    private let dragThreshold: CGFloat = 40
    
    // MARK: - Computed Heights
    
    private var showMetrics: Bool {
        driveState == .driving || driveState == .stopped
    }
    
    private var collapsedHeight: CGFloat {
        handleHeight + statusHeight
    }
    
    private var expandedHeight: CGFloat {
        handleHeight + statusHeight + tabsHeight + (showMetrics ? extraStatsHeight : 0)
    }
    
    private var currentHeight: CGFloat {
        isExpanded ? expandedHeight : collapsedHeight
    }
    
    // MARK: - Body
    
    var body: some View {
        VStack(spacing: 0) {
            // 1. Drag Handle (always)
            dragHandle
            
            // 2. Status Row (always)
            statusRow
            
            // 3. Extra Stats (only if expanded && driving)
            if isExpanded && showMetrics {
                extraStatsRow
            }
            
            // 4. Tabs Footer (only if expanded)
            if isExpanded {
                tabsRow
            }
        }
        .frame(height: currentHeight)
        .frame(maxWidth: .infinity)
        .background(
            Color.black
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 20,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 20
                    )
                )
        )
        .background(Color.black)
        .contentShape(Rectangle())
        .highPriorityGesture(dragGesture)
        .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.9), value: isExpanded)
    }
    
    // MARK: - Drag Handle
    
    private var dragHandle: some View {
        RoundedRectangle(cornerRadius: 2.5)
            .fill(Color.white.opacity(0.3))
            .frame(width: 36, height: 5)
            .frame(height: handleHeight)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())  // Expand tap area
            .onTapGesture {
                withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.9)) {
                    isExpanded.toggle()
                }
            }
    }
    
    // MARK: - Status Row
    
    @ViewBuilder
    private var statusRow: some View {
        if showMetrics {
            metricsRow
        } else {
            idleRow
        }
    }
    
    private var idleRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.gray)
                .frame(width: 8, height: 8)
            
            Text("Idle")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
            
            Spacer()
        }
        .padding(.leading, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: statusHeight)
        .transaction { $0.animation = nil }
    }
    
    private var metricsRow: some View {
        HStack(spacing: 0) {
            metricItem(value: String(format: "%.0f", speed), unit: "mph")
            
            Divider()
                .frame(height: 28)
                .background(Color.white.opacity(0.2))
            
            metricItem(value: String(format: "%.1f", distance), unit: "mi")
            
            Divider()
                .frame(height: 28)
                .background(Color.white.opacity(0.2))
            
            metricItem(value: formattedDuration, unit: nil)
            
            if let onEndDrive {
                Button(action: onEndDrive) {
                    Image(systemName: "stop.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.red)
                }
                .padding(.trailing, 12)
            }
        }
        .frame(height: statusHeight)
        .transaction { $0.animation = nil }
    }
    
    // MARK: - Extra Stats Row
    
    private var extraStatsRow: some View {
        HStack(spacing: 24) {
            statItem(label: "Avg", value: String(format: "%.0f mph", avgSpeed))
            statItem(label: "Max", value: String(format: "%.0f mph", maxSpeed))
            statItem(label: "Points", value: "\(pointCount)")
        }
        .frame(height: extraStatsHeight)
        .transition(.opacity)
    }
    
    // MARK: - Tabs Footer Row
    
    private var tabsRow: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                tabButton(for: tab)
            }
        }
        .frame(height: tabsHeight)
        .transition(.opacity)
    }
    
    private func tabButton(for tab: AppTab) -> some View {
        Button {
            selectedTab = tab
        } label: {
            VStack(spacing: 4) {
                Image(systemName: tab.icon)
                    .font(.title3)
                
                Text(tab.title)
                    .font(.caption2)
            }
            .foregroundStyle(selectedTab == tab ? .blue : .white.opacity(0.6))
            .frame(maxWidth: .infinity)
        }
        .transaction { $0.animation = nil }
    }
    
    // MARK: - Drag Gesture
    
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onEnded { value in
                let translation = value.translation.height
                
                // Threshold-based, not velocity-only
                if translation < -dragThreshold {
                    withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.9)) {
                        isExpanded = true
                    }
                } else if translation > dragThreshold {
                    withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.9)) {
                        isExpanded = false
                    }
                }
            }
    }
    
    // MARK: - Helpers
    
    private func metricItem(value: String, unit: String?) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .monospacedDigit()
            
            if let unit {
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity)
    }
    
    private func statItem(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
            
            Text(value)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.white.opacity(0.8))
                .monospacedDigit()
        }
    }
    
    private var formattedDuration: String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

#Preview("Idle - Collapsed") {
    VStack {
        Spacer()
        NavigationBar(
            selectedTab: .constant(.map),
            isExpanded: .constant(false),
            driveState: .idle,
            speed: 0, distance: 0, duration: 0,
            avgSpeed: 0, maxSpeed: 0, pointCount: 0,
            onEndDrive: nil
        )
    }
    .background(Color.gray.opacity(0.3))
}

#Preview("Driving - Collapsed") {
    VStack {
        Spacer()
        NavigationBar(
            selectedTab: .constant(.map),
            isExpanded: .constant(true),
            driveState: .driving,
            speed: 42, distance: 12.4, duration: 1845,
            avgSpeed: 38, maxSpeed: 65, pointCount: 342,
            onEndDrive: {}
        )
    }
    .background(Color.gray.opacity(0.3))
}

