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
                // Release image memory when scrolling off-screen
                snapshotImage = nil
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
        guard snapshotImage == nil else { return }

        isLoading = true
        snapshotImage = await renderer.render(
            drive: drive,
            size: size,
            scale: UIScreen.main.scale
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
