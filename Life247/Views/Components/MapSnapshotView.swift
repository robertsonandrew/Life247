//
//  MapSnapshotView.swift
//  Life247
//
//  Created by Andrew Robertson on 1/23/26.
//

import SwiftUI
import MapKit
import UIKit

/// A view that asynchronously loads a static map snapshot.
/// Replaces heavy Map() views in lists.
struct MapSnapshotView: View {
    let drive: Drive
    let width: CGFloat
    let height: CGFloat
    
    @State private var snapshotImage: UIImage?
    @State private var isLoading = false
    
    var body: some View {
        Group {
            if let image = snapshotImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color(.secondarySystemGroupedBackground)
                    if isLoading {
                        ProgressView()
                    }
                }
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .task {
            // Check cache or generate
            if snapshotImage == nil {
                isLoading = true
                await generateSnapshot()
                isLoading = false
            }
        }
    }
    
    private func generateSnapshot() async {
        guard let (center, span) = drive.routeBounds else { return }
        
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: center, span: span)
        options.size = CGSize(width: width, height: height)
        options.scale = UIScreen.main.scale
        options.mapType = .hybrid
        options.showsBuildings = true
        
        // Force Dark Mode
        options.traitCollection = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: .dark),
            UITraitCollection(displayScale: UIScreen.main.scale)
        ])
        
        let snapshotter = MKMapSnapshotter(options: options)
        
        do {
            let snapshot = try await snapshotter.start()
            let image = snapshot.image
            
            // Draw route on snapshot
            let finalImage = UIGraphicsImageRenderer(size: options.size).image { _ in
                image.draw(at: .zero)
                
                // Draw path
                let path = UIBezierPath()
                let points = drive.pointsChronological.map { $0.coordinate }
                
                guard points.count > 1 else { return }
                
                let firstPoint = snapshot.point(for: points[0])
                path.move(to: firstPoint)
                
                for point in points.dropFirst() {
                    path.addLine(to: snapshot.point(for: point))
                }
                
                // Stroke style
                path.lineWidth = 4
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                UIColor.systemBlue.setStroke()
                path.stroke()
                
                // Draw start/end markers
                if let start = points.first {
                    drawMarker(at: snapshot.point(for: start), color: .systemGreen)
                }
                if let end = points.last {
                    drawMarker(at: snapshot.point(for: end), color: .systemRed)
                }
            }
            
            await MainActor.run {
                self.snapshotImage = finalImage
            }
        } catch {
            print("Failed to generate snapshot: \(error)")
        }
    }
    
    private func drawMarker(at point: CGPoint, color: UIColor) {
        let radius: CGFloat = 6
        let path = UIBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        color.setFill()
        path.fill()
        UIColor.white.setStroke()
        path.lineWidth = 2
        path.stroke()
    }
}
