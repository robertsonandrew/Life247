//
//  TimelineCardStyle.swift
//  Life247
//
//  Created by Andrew Robertson on 1/18/26.
//

import SwiftUI

/// Shared card styling for timeline rows (Drive/Stop).
struct TimelineCardStyle: ViewModifier {
    var cornerRadius: CGFloat = 18
    var verticalPadding: CGFloat = 10
    var horizontalPadding: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .padding(.vertical, verticalPadding)
            .padding(.horizontal, horizontalPadding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            )
    }
}

extension View {
    func timelineCardStyle(
        cornerRadius: CGFloat = 18,
        verticalPadding: CGFloat = 10,
        horizontalPadding: CGFloat = 12
    ) -> some View {
        modifier(
            TimelineCardStyle(
                cornerRadius: cornerRadius,
                verticalPadding: verticalPadding,
                horizontalPadding: horizontalPadding
            )
        )
    }
}
