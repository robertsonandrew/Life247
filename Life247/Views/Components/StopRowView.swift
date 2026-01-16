//
//  StopRowView.swift
//  Life247
//
//  Created by Andrew Robertson on 1/15/26.
//

import SwiftUI
import CoreLocation

/// Compact row view for an inferred stop in the timeline.
struct StopRowView: View {
    let stop: InferredStop
    let frequentStopInfo: FrequentStopCandidate?
    
    init(stop: InferredStop, frequentStopInfo: FrequentStopCandidate? = nil) {
        self.stop = stop
        self.frequentStopInfo = frequentStopInfo
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: stop.displayIcon)
                .font(.title2)
                .foregroundStyle(frequentStopInfo != nil ? .purple : .orange)
                .frame(width: 40)
            
            // Content
            VStack(alignment: .leading, spacing: 4) {
                // Type label with optional frequent badge
                HStack(spacing: 6) {
                    Text("STOP")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(frequentStopInfo != nil ? .purple : .orange)
                    
                    if let frequent = frequentStopInfo {
                        Text("• \(frequent.visitLabel)")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.purple)
                    }
                }
                
                // Location name or address
                if frequentStopInfo != nil && stop.matchedPlace == nil {
                    Text("Frequent Stop")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                } else {
                    Text(stop.displayName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                }
                
                // Duration and time range
                HStack(spacing: 8) {
                    Label(stop.formattedDuration, systemImage: "clock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Text("•")
                        .foregroundStyle(.secondary)
                    
                    Text(stop.timeRangeString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

#Preview {
    List {
        StopRowView(stop: InferredStop(
            id: UUID(),
            location: .init(latitude: 36.0, longitude: -95.9),
            startTime: Date().addingTimeInterval(-3600),
            endTime: Date().addingTimeInterval(-3000),
            matchedPlace: nil,
            address: "15060 S Grant St"
        ))
        
        StopRowView(
            stop: InferredStop(
                id: UUID(),
                location: .init(latitude: 36.0, longitude: -95.9),
                startTime: Date().addingTimeInterval(-7200),
                endTime: Date().addingTimeInterval(-3600),
                matchedPlace: nil,
                address: "123 Main St"
            ),
            frequentStopInfo: FrequentStopCandidate(
                coordinate: .init(latitude: 36.0, longitude: -95.9),
                visitCount: 5,
                totalDuration: 3600,
                lastVisited: Date()
            )
        )
    }
}
