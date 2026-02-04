//
//  NavigationPuck.swift
//  Life247
//
//  Created by Andrew Robertson on 1/16/26.
//

import SwiftUI
import MapKit

// MARK: - Navigation Puck

/// Apple-Maps–style navigation puck with:
/// • External state control (stopped/moving from LocationInterpolator)
/// • Heading dead-zone smoothing
/// • Velocity-based tilt
/// • Zoom-aware scaling (shrinks when zoomed in)
/// Note: Accuracy ring is now rendered as a MapCircle on the map surface for geo-accuracy.
struct NavigationPuck: View {
    let heading: CLLocationDirection?
    let speed: Double                // mph (for tilt calculation)
    let puckState: PuckState         // External state from LocationInterpolator
    let cameraDistance: Double       // meters from ground

    // MARK: - Heading smoothing
    @State private var displayedHeading: Double = 0

    private let headingDeadZone: Double = 1.0 // degrees

    // MARK: - Derived values

    private var normalizedHeading: Double {
        guard let heading else { return displayedHeading }
        let value = heading.truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }

    /// Convenience for state check
    private var isStopped: Bool {
        puckState == .stopped
    }
    
    /// Subtle pitch forward as speed increases (0 when stopped)
    private var tiltAngle: Double {
        guard !isStopped else { return 0 }
        let clampedSpeed = min(max(speed, 0), 80) // mph cap
        return -(clampedSpeed / 80) * 8            // max ~8°
    }

    /// Camera-distance driven scale
    private var zoomScale: CGFloat {
        // Tuned for street → city → regional zooms
        let minScale: CGFloat = 0.85
        let maxScale: CGFloat = 1.15

        // Map distance → scalar
        let t = log10(max(cameraDistance, 50)) / log10(10_000)
        let scale = maxScale - CGFloat(t) * (maxScale - minScale)

        return min(max(scale, minScale), maxScale)
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            // Explicit bounds anchor - forces MapKit to use this size
            Color.clear
                .frame(width: PuckMetrics.hitboxSize, height: PuckMetrics.hitboxSize)

            // Stop-state dot (always present, crossfade with arrow)
            StopDot()
                .scaleEffect(isStopped ? zoomScale : zoomScale * 0.5)
                .opacity(isStopped ? 1.0 : 0.0)
                .animation(.easeInOut(duration: 0.3), value: isStopped)
            
            // Arrow puck (always present, crossfade with dot)
            ArrowPuck(
                heading: isStopped ? displayedHeading : displayedHeading,  // Use heading in both states for bearing cone
                tilt: tiltAngle
            )
            .scaleEffect(isStopped ? zoomScale * 0.5 : zoomScale)
            .opacity(isStopped ? 0.0 : 1.0)
            .animation(.easeInOut(duration: 0.3), value: isStopped)
        }
        .frame(width: PuckMetrics.hitboxSize, height: PuckMetrics.hitboxSize)
        .contentShape(Rectangle())
        .allowsHitTesting(false)
        .onAppear {
            displayedHeading = normalizedHeading
        }
        .onChange(of: normalizedHeading) { _, newValue in
            let delta = abs(newValue - displayedHeading)
            if delta > headingDeadZone {
                displayedHeading = newValue
            }
        }
    }
}

// MARK: - Arrow Puck

struct ArrowPuck: View {
    let heading: Double
    let tilt: Double

    var body: some View {
        ZStack {
            // Shadow
            NavigationArrowShape()
                .fill(Color.black.opacity(0.28))
                .frame(width: PuckMetrics.size, height: PuckMetrics.size)
                .blur(radius: 6)
                .offset(y: 6)

            // Body with gradient
            NavigationArrowShape()
                .fill(PuckMetrics.bodyGradient)
                .frame(width: PuckMetrics.size, height: PuckMetrics.size)

            // Center line highlight
            Rectangle()
                .fill(Color.white.opacity(0.3))
                .frame(width: 1.5, height: PuckMetrics.size * 0.65)
                .offset(y: -PuckMetrics.size * 0.05)

            // Outline
            NavigationArrowShape()
                .stroke(
                    Color.white,
                    style: StrokeStyle(
                        lineWidth: 3,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .frame(width: PuckMetrics.size, height: PuckMetrics.size)
        }
        .rotationEffect(.degrees(heading))  // Shape points up, heading 0 = north
        .rotation3DEffect(
            .degrees(tilt),
            axis: (x: 1, y: 0, z: 0),
            perspective: 0.7
        )
        .animation(
            .interactiveSpring(response: 0.28, dampingFraction: 0.75),
            value: heading
        )
        .animation(
            .easeOut(duration: 0.25),
            value: tilt
        )
    }
}

// MARK: - Metrics

private enum PuckMetrics {
    static let size: CGFloat = 48
    static let dotSize: CGFloat = 28  // Stop-state dot size
    static let hitboxSize: CGFloat = 160  // Layout hitbox for MapKit annotation container

    static let bodyGradient = LinearGradient(
        colors: [
            Color(red: 0.25, green: 0.90, blue: 1.00),  // Bright cyan top
            Color(red: 0.08, green: 0.60, blue: 0.78)   // Deeper teal bottom
        ],
        startPoint: .top,
        endPoint: .bottom
    )
}

// MARK: - Stop Dot

/// Stationary location indicator when stopped
struct StopDot: View {
    var body: some View {
        ZStack {
            // Shadow
            Circle()
                .fill(Color.black.opacity(0.28))
                .frame(width: PuckMetrics.dotSize, height: PuckMetrics.dotSize)
                .blur(radius: 4)
                .offset(y: 3)
            
            // Body with gradient
            Circle()
                .fill(PuckMetrics.bodyGradient)
                .frame(width: PuckMetrics.dotSize, height: PuckMetrics.dotSize)
            
            // Outline
            Circle()
                .stroke(Color.white, lineWidth: 3)
                .frame(width: PuckMetrics.dotSize, height: PuckMetrics.dotSize)
        }
    }
}

// MARK: - Navigation Arrow Shape

/// Perfectly symmetric navigation arrow pointing up
struct NavigationArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var path = Path()
        
        // Start at the top (apex)
        path.move(to: CGPoint(x: w * 0.5, y: 0))
        
        // Right side - curve to bottom right
        path.addQuadCurve(
            to: CGPoint(x: w, y: h * 0.82),
            control: CGPoint(x: w * 0.85, y: h * 0.45)
        )
        
        // Right inner curve to center notch
        path.addQuadCurve(
            to: CGPoint(x: w * 0.5, y: h * 0.70),
            control: CGPoint(x: w * 0.72, y: h * 0.78)
        )
        
        // Left inner curve from center notch
        path.addQuadCurve(
            to: CGPoint(x: 0, y: h * 0.82),
            control: CGPoint(x: w * 0.28, y: h * 0.78)
        )
        
        // Left side - curve back to top
        path.addQuadCurve(
            to: CGPoint(x: w * 0.5, y: 0),
            control: CGPoint(x: w * 0.15, y: h * 0.45)
        )
        
        path.closeSubpath()
        return path
    }
}
