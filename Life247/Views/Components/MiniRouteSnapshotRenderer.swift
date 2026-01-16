//
//  MiniRouteSnapshotRenderer.swift
//  Life247
//
//  Created by Andrew Robertson on 1/15/26.
//

import MapKit
import UIKit
import Combine

/// Isolated, cancelable renderer for route map snapshots.
/// Handles async snapshot generation and route drawing.
final class MiniRouteSnapshotRenderer: ObservableObject {
    private var task: Task<UIImage?, Never>?

    @MainActor
    func cancel() {
        task?.cancel()
        task = nil
    }

    @MainActor
    func render(
        drive: Drive,
        size: CGSize,
        scale: CGFloat
    ) async -> UIImage? {
        cancel()

        guard let bounds = drive.routeBounds else { return nil }
        
        // Add padding so routes aren't clipped at edges
        let paddedSpan = MKCoordinateSpan(
            latitudeDelta: bounds.span.latitudeDelta * 1.5,
            longitudeDelta: bounds.span.longitudeDelta * 1.5
        )

        task = Task {
            let options = MKMapSnapshotter.Options()
            options.region = MKCoordinateRegion(
                center: bounds.center,
                span: paddedSpan
            )
            options.size = size
            options.scale = scale
            options.mapType = .standard
            options.showsBuildings = false
            options.pointOfInterestFilter = .excludingAll

            let snapshotter = MKMapSnapshotter(options: options)

            return await withTaskCancellationHandler {
                do {
                    let snapshot = try await snapshotter.start()
                    return Self.drawRoute(on: snapshot, drive: drive)
                } catch {
                    return nil
                }
            } onCancel: {
                snapshotter.cancel()
            }
        }

        return await task?.value
    }
}

// MARK: - Route Drawing

extension MiniRouteSnapshotRenderer {
    static func drawRoute(
        on snapshot: MKMapSnapshotter.Snapshot,
        drive: Drive
    ) -> UIImage {
        let image = snapshot.image

        UIGraphicsBeginImageContextWithOptions(
            image.size,
            true,
            image.scale
        )
        image.draw(at: .zero)

        guard let context = UIGraphicsGetCurrentContext() else {
            UIGraphicsEndImageContext()
            return image
        }

        // Clip to visible bounds
        context.addRect(CGRect(origin: .zero, size: image.size))
        context.clip()

        let points = drive.sampledPoints(maxCount: 100)
        guard points.count > 1 else {
            UIGraphicsEndImageContext()
            return image
        }

        context.setStrokeColor(UIColor.systemBlue.cgColor)
        context.setLineWidth(3)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let coordinates = points.map(\.coordinate)

        for (index, coord) in coordinates.enumerated() {
            let point = snapshot.point(for: coord)
            index == 0 ? context.move(to: point) : context.addLine(to: point)
        }

        context.strokePath()

        // Start marker (green)
        if let start = coordinates.first {
            let point = snapshot.point(for: start)
            context.setFillColor(UIColor.systemGreen.cgColor)
            context.fillEllipse(in: CGRect(
                x: point.x - 6,
                y: point.y - 6,
                width: 12,
                height: 12
            ))
        }

        // End marker (red)
        if let end = coordinates.last {
            let point = snapshot.point(for: end)
            context.setFillColor(UIColor.systemRed.cgColor)
            context.fillEllipse(in: CGRect(
                x: point.x - 6,
                y: point.y - 6,
                width: 12,
                height: 12
            ))
        }

        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return result ?? image
    }
}
