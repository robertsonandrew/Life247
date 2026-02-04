//
//  MiniRouteMap.swift
//  Life247
//
//  Created by Andrew Robertson on 1/15/26.
//

import SwiftUI
import MapKit

/// Lightweight static route map for history list rows.
/// Uses MKMapSnapshotter for smooth scrolling and deterministic rendering.
struct MiniRouteMap: View {
    let drive: Drive
    let height: CGFloat

    @State private var snapshotImage: UIImage?
    @State private var isLoading = true

    @StateObject private var renderer = MiniRouteSnapshotRenderer()

    init(drive: Drive, height: CGFloat = 100) {
        self.drive = drive
        self.height = height
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Always show placeholder as base
                placeholder
                
                if let image = snapshotImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                        .transition(.opacity.animation(.easeIn(duration: 0.2)))
                }
            }
            .frame(height: height)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .task(id: drive.id) {
                await generateSnapshot(size: geo.size)
            }
            .onDisappear {
                // Cancel in-flight snapshot work.
                // Don't clear `snapshotImage` here: list cell reuse would cause
                // expensive re-snapshotting when the user scrolls back.
                renderer.cancel()
            }
        }
        .frame(height: height)
    }

    private var placeholder: some View {
        Rectangle()
            .fill(.secondary.opacity(0.1))
    }

    @MainActor
    private func generateSnapshot(size: CGSize) async {
        guard size.width > 1, size.height > 1 else { return }
        guard drive.points.count > 1 else { return }
        guard snapshotImage == nil else { return }

        // HACK: Request a taller image to push the Apple Maps logo/legal text off data
        // We align the image to the .top of the view, causing the bottom (with logo) to be clipped.
        let logoBleed: CGFloat = 40
        let captureSize = CGSize(width: size.width, height: size.height + logoBleed)
        
        // Use a reasonable default scale since UIScreen.main is deprecated in iOS 26
        let displayScale: CGFloat = 3.0

        isLoading = true
        snapshotImage = await renderer.render(
            drive: drive,
            size: captureSize,
            scale: displayScale
        )
        isLoading = false
    }
}

#Preview {
    MiniRouteMap(drive: Drive(
        startTime: Date().addingTimeInterval(-3600),
        endTime: Date(),
        distanceMeters: 8046.72
    ), height: 160)
    .padding()
}
