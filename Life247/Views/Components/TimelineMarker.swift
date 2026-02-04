//
//  TimelineMarker.swift
//  Life247
//
//  Created by Andrew Robertson on 1/18/26.
//

import SwiftUI

/// Timeline spine + node used in the History timeline.
struct TimelineMarker: View {
    let isFirst: Bool
    let isLast: Bool
    let color: Color
    let symbol: String?
    
    /// Whether to use dashed lines (for stop segments)
    var isDashed: Bool = false

    var body: some View {
        ZStack {
            // Spine
            VStack(spacing: 0) {
                // Top segment
                if isFirst {
                    Color.clear
                        .frame(width: 2)
                } else if isDashed {
                    DashedLine()
                        .stroke(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
                        .frame(width: 2)
                } else {
                    Rectangle()
                        .fill(Color.white.opacity(0.14))
                        .frame(width: 2)
                }
                
                // Bottom segment
                if isLast {
                    Color.clear
                        .frame(width: 2)
                } else if isDashed {
                    DashedLine()
                        .stroke(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
                        .frame(width: 2)
                } else {
                    Rectangle()
                        .fill(Color.white.opacity(0.14))
                        .frame(width: 2)
                }
            }

            // Node
            if let symbol {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(color)
                    .padding(6)
                    .background(
                        Circle()
                            .fill(Color(uiColor: .systemBackground).opacity(0.9))
                    )
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 10, height: 10)
                    .background(
                        Circle()
                            .fill(Color(uiColor: .systemBackground).opacity(0.9))
                            .frame(width: 16, height: 16)
                    )
            }
        }
        .frame(width: 34)
    }
}

/// Shape for drawing a vertical dashed line
struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}
