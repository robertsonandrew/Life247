//
//  SuggestedPlaceRowView.swift
//  Life247
//
//  Created by Andrew Robertson on 1/28/26.
//

import SwiftUI
import MapKit

/// A row displaying a FrequentStopCandidate as a suggested place.
struct SuggestedPlaceRowView: View {
    let candidate: FrequentStopCandidate
    var durationText: String? = nil
    var onAdd: (() -> Void)? = nil
    
    var body: some View {
        HStack(spacing: 12) {
            // Mini map snapshot
            MiniMapView(coordinate: candidate.coordinate)
                .frame(width: 50, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "lightbulb.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                    
                    Text(candidate.visitLabel)
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                
                if let durationText {
                    Text(durationText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Last visited \(candidate.lastVisited.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            if let onAdd {
                Button(action: onAdd) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Mini Map View

/// A small, non-interactive map thumbnail.
private struct MiniMapView: View {
    let coordinate: CLLocationCoordinate2D
    
    var body: some View {
        Map(initialPosition: .region(region)) {
            Marker("", coordinate: coordinate)
                .tint(.blue)
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .disabled(true)
        .allowsHitTesting(false)
    }
    
    private var region: MKCoordinateRegion {
        MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 200,
            longitudinalMeters: 200
        )
    }
}

#Preview {
    List {
        SuggestedPlaceRowView(
            candidate: FrequentStopCandidate(
                coordinate: CLLocationCoordinate2D(latitude: 36.0, longitude: -95.9),
                visitCount: 5,
                totalDuration: 3600 * 3,
                lastVisited: Date().addingTimeInterval(-86400)
            )
        )
    }
}
