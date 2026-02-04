//
//  BottomBar.swift
//  Life247
//
//  Created by Andrew Robertson on 1/16/26.
//

import SwiftUI

/// Unified bottom bar combining DriveSheet and TabBar.
/// Height-based bottom sheet (Apple Maps–style) with velocity-based snapping.
struct BottomBar: View {
    // Navigation
    @Binding var selectedTab: AppTab
    
    // Drive state
    let driveState: DriveState
    let speed: Double
    let distance: Double
    let duration: TimeInterval
    let avgSpeed: Double
    let maxSpeed: Double
    let pointCount: Int
    let onEndDrive: (() -> Void)?
    
    // Only show drive sheet on Map tab
    let showDriveSheet: Bool
    
    // MARK: - Sheet Detents
    private enum SheetDetent: CGFloat, CaseIterable {
        case peek = 56       // Collapsed - just status
        case medium = 160    // Mid-height - summary content
        case full = 280      // Fully expanded - all details
        
        var next: SheetDetent {
            switch self {
            case .peek: return .medium
            case .medium: return .full
            case .full: return .peek
            }
        }
    }
    
    // MARK: - Sheet State
    @State private var currentDetent: SheetDetent = .peek
    @GestureState private var dragOffset: CGFloat = 0
    
    // MARK: - Layout Constants
    private let tabBarHeight: CGFloat = 56
    private let handleHeight: CGFloat = 20
    private let sheetCornerRadius: CGFloat = 0
    private let rubberBandFactor: CGFloat = 0.3  // Resistance when over-dragging

    private let selectedTabTint: Color = .red
    
    // Tab bar styling (darker)
    private let tabBarMaterial: Material = .thickMaterial
    private let tabBarScrimOpacity: Double = 0.75
    
    private var showMetrics: Bool {
        driveState == .driving || driveState == .stopped
    }
    
    // Dynamic Height Reporting
    @Binding var visibleHeight: CGFloat
    
    // MARK: - Body
    var body: some View {
        VStack(spacing: 0) {
            if showDriveSheet {
                driveSheet
            }
            
            // Horizontal separator between sheet and tab bar
            Rectangle()
                .fill(Color(white: 0.35))  // Subtle dark gray, fully opaque
                .frame(height: 1)
            
            tabBar
        }
        // No shared background - each section has its own
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 1)
        }
        // Report height via binding (more reliable for parent state)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onChange(of: geo.size.height, initial: true) { _, newHeight in
                        visibleHeight = newHeight
                    }
            }
        )
        // Also continue reporting via preference for other consumers (if any)
        .reportBottomBarHeight()
    }
    
    // MARK: - Drive Sheet
    private var driveSheet: some View {
        VStack(spacing: 0) {
            dragHandle
            
            ZStack(alignment: .top) {
                // Peek content fades out as we expand
                peekContent
                    .opacity(Double(1 - min(expandProgress * 2, 1)))
                
                // Expanded content fades in after 25% expansion
                expandedContent
                    .opacity(Double(max(0, (expandProgress - 0.25) * 1.5)))
            }
            .frame(height: computedHeight - handleHeight, alignment: .top)
            .clipped()
        }
        .frame(height: computedHeight)
        .frame(maxWidth: .infinity)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: sheetCornerRadius,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: sheetCornerRadius
            )
            .fill(Color.black.opacity(0.9))
        )
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: sheetCornerRadius,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: sheetCornerRadius
            )
            .fill(.ultraThinMaterial)
        )
        .overlay(alignment: .top) {
            UnevenRoundedRectangle(
                topLeadingRadius: sheetCornerRadius,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: sheetCornerRadius
            )
            .stroke(Color.white.opacity(0.10), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .highPriorityGesture(dragGesture)
        .onTapGesture {
            cycleDetent()
        }
    }
    
    // MARK: - Drag Handle
    private var dragHandle: some View {
        RoundedRectangle(cornerRadius: 2.5)
            .fill(Color.white.opacity(0.3))
            .frame(width: 36, height: 5)
            .frame(height: handleHeight)
            .frame(maxWidth: .infinity)
    }
    
    // MARK: - Peek Content
    private var peekContent: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            
            Text(statusText)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.white)
            
            Spacer()
            
            if showMetrics {
                Text(String(format: "%.0f mph", speed))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(.white)
                
                Text("•")
                    .foregroundStyle(.white.opacity(0.5))
                
                Text(String(format: "%.1f mi", distance))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 24)
        .frame(height: SheetDetent.peek.rawValue - handleHeight)
    }
    
    // MARK: - Expanded Content
    private var expandedContent: some View {
        VStack(spacing: 12) {
            if showMetrics {
                HStack(spacing: 0) {
                    metricItem(value: String(format: "%.0f", speed), unit: "mph", label: "Speed")
                    divider
                    metricItem(value: String(format: "%.1f", distance), unit: "mi", label: "Distance")
                    divider
                    metricItem(value: formattedDuration, unit: nil, label: "Duration")
                }
                
                HStack(spacing: 20) {
                    statItem(label: "Avg", value: String(format: "%.0f mph", avgSpeed))
                    statItem(label: "Max", value: String(format: "%.0f mph", maxSpeed))
                    statItem(label: "Points", value: "\(pointCount)")
                    
                    if let onEndDrive {
                        Spacer()
                        Button(action: onEndDrive) {
                            Image(systemName: "stop.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.red)
                        }
                    }
                }
                .padding(.horizontal, 24)
            } else {
                peekContent
            }
        }
        .padding(.top, 8)
    }
    
    private var divider: some View {
        Divider()
            .frame(height: 36)
            .background(Color.white.opacity(0.2))
    }
    
    // MARK: - Tab Bar
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Image(systemName: tab.icon)
                        .font(.title)
                        .foregroundStyle(selectedTab == tab ? selectedTabTint : .white.opacity(0.6))
                        .frame(maxWidth: .infinity)
                }
                .frame(maxHeight: .infinity)
                .buttonStyle(.plain)
            }
        }
        .frame(height: tabBarHeight)
        .background(Color.black.opacity(tabBarScrimOpacity))
        .background(tabBarMaterial)
    }
    
    // MARK: - Drag Gesture & Detent Logic
    
    private var computedHeight: CGFloat {
        let baseHeight = currentDetent.rawValue
        let rawHeight = baseHeight + dragOffset
        
        // Rubber-band effect: allow over-drag with resistance
        let minHeight = SheetDetent.peek.rawValue
        let maxHeight = SheetDetent.full.rawValue
        
        if rawHeight < minHeight {
            let overDrag = minHeight - rawHeight
            return minHeight - (overDrag * rubberBandFactor)
        } else if rawHeight > maxHeight {
            let overDrag = rawHeight - maxHeight
            return maxHeight + (overDrag * rubberBandFactor)
        }
        return rawHeight
    }
    
    private var expandProgress: CGFloat {
        // 0 at peek, 0.5 at medium, 1 at full
        let minH = SheetDetent.peek.rawValue
        let maxH = SheetDetent.full.rawValue
        return (computedHeight - minH) / (maxH - minH)
    }
    
    private func cycleDetent() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            currentDetent = currentDetent.next
        }
    }
    
    private func snapToNearestDetent(velocity: CGFloat, currentHeight: CGFloat) {
        let detents = SheetDetent.allCases.map { $0.rawValue }.sorted()
        
        // Find nearest detent, biased by velocity
        var targetHeight = currentHeight
        if abs(velocity) > 200 {
            // Fast swipe: go in velocity direction
            targetHeight = velocity > 0 ? currentHeight + 100 : currentHeight - 100
        }
        
        // Snap to closest detent
        let nearest = detents.min(by: { abs($0 - targetHeight) < abs($1 - targetHeight) }) ?? SheetDetent.peek.rawValue
        let newDetent = SheetDetent.allCases.first { $0.rawValue == nearest } ?? .peek
        
        // Haptic feedback
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            currentDetent = newDetent
        }
    }
    
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .updating($dragOffset) { value, state, transaction in
                // Disable animation during drag for smooth tracking
                transaction.animation = nil
                state = -value.translation.height
            }
            .onEnded { value in
                let velocity = -value.predictedEndLocation.y + value.location.y
                let translation = -value.translation.height
                let currentHeight = currentDetent.rawValue + translation
                
                snapToNearestDetent(velocity: velocity, currentHeight: currentHeight)
            }
    }
    
    // MARK: - Helpers
    private var statusColor: Color {
        switch driveState {
        case .idle: return .gray
        case .maybeDriving: return .yellow
        case .driving: return .green
        case .pendingArrival: return .orange
        case .stopped: return .orange
        case .ended: return .blue
        }
    }
    
    private var statusText: String {
        switch driveState {
        case .idle: return "Idle"
        case .maybeDriving: return "Detecting..."
        case .driving: return "Driving"
        case .pendingArrival: return "Verifying Arrival"
        case .stopped: return "Stopped"
        case .ended: return "Drive Ended"
        }
    }
    
    private func metricItem(value: String, unit: String?, label: String) -> some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(.white)
                
                if let unit {
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
    }
    
    private func statItem(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.8))
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

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        return min(max(self, limits.lowerBound), limits.upperBound)
    }
}
