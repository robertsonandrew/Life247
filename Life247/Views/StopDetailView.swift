//
//  StopDetailView.swift
//  Life247
//
//  Created by Andrew Robertson on 1/15/26.
//

import SwiftUI
import MapKit

/// Detail view for an inferred stop showing location on a map.
struct StopDetailView: View {
    let stop: InferredStop
    let frequentStopInfo: FrequentStopCandidate?
    @State private var cameraPosition: MapCameraPosition
    @State private var showingSaveAsPlace = false
    
    init(stop: InferredStop, frequentStopInfo: FrequentStopCandidate? = nil) {
        self.stop = stop
        self.frequentStopInfo = frequentStopInfo
        _cameraPosition = State(
            initialValue: .region(
                MKCoordinateRegion(
                    center: stop.location,
                    span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
                )
            )
        )
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Map showing stop location
            Map(position: $cameraPosition) {
                Annotation(stop.displayName, coordinate: stop.location) {
                    VStack(spacing: 0) {
                        Image(systemName: stop.displayIcon)
                            .font(.title)
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(frequentStopInfo != nil ? .purple : .orange)
                            .clipShape(Circle())
                        
                        // Pin tail
                        Triangle()
                            .fill(frequentStopInfo != nil ? .purple : .orange)
                            .frame(width: 16, height: 10)
                            .rotationEffect(.degrees(180))
                            .offset(y: -2)
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            
            // Details card
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Location
                    HStack(spacing: 12) {
                        Image(systemName: stop.displayIcon)
                            .font(.title2)
                            .foregroundStyle(frequentStopInfo != nil ? .purple : .orange)
                            .frame(width: 40)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stop.displayName)
                                .font(.headline)
                            
                            if stop.matchedPlace == nil, let address = stop.address {
                                Text(address)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        
                        Spacer()
                    }
                    
                    Divider()
                    
                    // Duration (this stop)
                    HStack(spacing: 12) {
                        Image(systemName: "clock.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                            .frame(width: 40)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stop.formattedDuration)
                                .font(.headline)
                            
                            Text(stop.timeRangeString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                    }
                    
                    // Frequent stop stats (if applicable)
                    if let frequent = frequentStopInfo {
                        Divider()
                        
                        // Visit count
                        HStack(spacing: 12) {
                            Image(systemName: "repeat.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.purple)
                                .frame(width: 40)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(frequent.visitCount) visits")
                                    .font(.headline)
                                
                                Text("Frequent location")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Spacer()
                        }
                        
                        Divider()
                        
                        // Total time spent
                        HStack(spacing: 12) {
                            Image(systemName: "hourglass")
                                .font(.title2)
                                .foregroundStyle(.purple)
                                .frame(width: 40)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(formatTotalDuration(frequent.totalDuration))
                                    .font(.headline)
                                
                                Text("Total time spent")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Spacer()
                        }
                        
                        Divider()
                        
                        // Last visited
                        HStack(spacing: 12) {
                            Image(systemName: "calendar")
                                .font(.title2)
                                .foregroundStyle(.purple)
                                .frame(width: 40)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(frequent.lastVisited, style: .date)
                                    .font(.headline)
                                
                                Text("Last visited")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Spacer()
                        }
                    }
                    
                    Divider()
                    
                    // Coordinates
                    HStack(spacing: 12) {
                        Image(systemName: "location.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                            .frame(width: 40)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Coordinates")
                                .font(.headline)
                            
                            Text(String(format: "%.4f, %.4f", stop.location.latitude, stop.location.longitude))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                    }
                }
                .padding()
            }
            .background(.ultraThinMaterial)
            .contentMargins(.bottom, 100, for: .scrollContent)
        }
        .navigationTitle("Stop")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if stop.matchedPlace == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSaveAsPlace = true
                    } label: {
                        Label("Save as Place", systemImage: "mappin.and.ellipse")
                    }
                }
            }
        }
        .sheet(isPresented: $showingSaveAsPlace) {
            NavigationStack {
                SaveAsPlaceView(coordinate: stop.location)
            }
        }
    }
    
    private func formatTotalDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        
        if hours > 0 {
            return "\(hours) hr \(minutes) min total"
        } else {
            return "\(minutes) min total"
        }
    }
}

// MARK: - Triangle Shape

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

#Preview {
    NavigationStack {
        StopDetailView(
            stop: InferredStop(
                id: UUID(),
                location: .init(latitude: 36.0, longitude: -95.9),
                startTime: Date().addingTimeInterval(-3600),
                endTime: Date().addingTimeInterval(-3000),
                matchedPlace: nil,
                address: "15060 S Grant St"
            ),
            frequentStopInfo: FrequentStopCandidate(
                coordinate: .init(latitude: 36.0, longitude: -95.9),
                visitCount: 5,
                totalDuration: 7200,
                lastVisited: Date()
            )
        )
    }
}
