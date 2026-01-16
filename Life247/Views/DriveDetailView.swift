//
//  DriveDetailView.swift
//  Life247
//
//  Created by Andrew Robertson on 1/14/26.
//

import SwiftUI
import MapKit

/// Detailed view of a single drive with map visualization and statistics.
struct DriveDetailView: View {
    let drive: Drive
    
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var isMapExpanded = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Map
                mapSection
                
                // Stats
                statsSection
                
                // Details
                detailsSection
            }
        }
        .contentMargins(.bottom, 100, for: .scrollContent)
        .navigationTitle("Drive Details")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            setupCamera()
        }
        .fullScreenCover(isPresented: $isMapExpanded) {
            ExpandedMapView(drive: drive)
        }
    }
    
    // MARK: - Map Section
    
    @AppStorage("showSpeedHeatMap") private var showSpeedHeatMap = false
    
    private var mapSection: some View {
        ZStack(alignment: .bottomTrailing) {
            Map(position: $cameraPosition) {
                // Route polyline (uses full resolution for detail view)
                if drive.points.count > 1 {
                    RoutePolyline(
                        points: drive.pointsChronological,
                        mode: showSpeedHeatMap ? .heatMap : .solid,
                        lineWidth: 5
                    )
                }
                
                // Start marker
                if let start = drive.startCoordinate {
                    Annotation("Start", coordinate: start) {
                        Image(systemName: "play.circle.fill")
                            .font(.title)
                            .foregroundStyle(.green)
                            .background(Circle().fill(.white).padding(2))
                    }
                }
                
                // End marker
                if let end = drive.endCoordinate {
                    Annotation("End", coordinate: end) {
                        Image(systemName: "flag.checkered.circle.fill")
                            .font(.title)
                            .foregroundStyle(.red)
                            .background(Circle().fill(.white).padding(2))
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            
            // Expand button
            Button {
                isMapExpanded = true
            } label: {
                HStack(spacing: 6) {
                    Text("Expand")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
            }
            .padding(12)
        }
        .frame(height: 300)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding()
    }
    
    // MARK: - Stats Section
    
    private var statsSection: some View {
        HStack(spacing: 16) {
            StatCard(
                title: "Distance",
                value: drive.formattedDistance,
                icon: "road.lanes"
            )
            
            StatCard(
                title: "Duration",
                value: drive.formattedDuration,
                icon: "clock.fill"
            )
            
            StatCard(
                title: "Avg Speed",
                value: String(format: "%.0f mph", drive.averageSpeedMPH),
                icon: "gauge.medium"
            )
        }
        .padding(.horizontal)
    }
    
    // MARK: - Details Section
    
    private var detailsSection: some View {
        VStack(spacing: 16) {
            // Time details
            GroupBox {
                VStack(spacing: 12) {
                    DetailRow(label: "Started", value: drive.startTime.formatted(date: .abbreviated, time: .shortened))
                    Divider()
                    DetailRow(label: "Ended", value: drive.endTime?.formatted(date: .abbreviated, time: .shortened) ?? "In Progress")
                }
            } label: {
                Label("Time", systemImage: "clock")
            }
            
            // Speed details
            GroupBox {
                VStack(spacing: 12) {
                    DetailRow(label: "Max Speed", value: String(format: "%.0f mph", drive.maxSpeedMPH))
                    Divider()
                    DetailRow(label: "Average Speed", value: String(format: "%.1f mph", drive.averageSpeedMPH))
                }
            } label: {
                Label("Speed", systemImage: "speedometer")
            }
            
            // Technical details
            GroupBox {
                VStack(spacing: 12) {
                    DetailRow(label: "GPS Points", value: "\(drive.points.count)")
                    Divider()
                    DetailRow(label: "Drive ID", value: drive.shortId)
                }
            } label: {
                Label("Technical", systemImage: "info.circle")
            }
        }
        .padding()
    }
    
    // MARK: - Helpers
    
    private func setupCamera() {
        guard let bounds = drive.routeBounds else { return }
        cameraPosition = .region(MKCoordinateRegion(center: bounds.center, span: bounds.span))
    }
}

// MARK: - Expanded Map View

struct ExpandedMapView: View {
    let drive: Drive
    @Environment(\.dismiss) private var dismiss
    
    @State private var cameraPosition: MapCameraPosition = .automatic
    @AppStorage("showSpeedHeatMap") private var showSpeedHeatMap = false
    
    var body: some View {
        ZStack {
            // Full screen map
            Map(position: $cameraPosition) {
                // Route polyline
                if drive.points.count > 1 {
                    RoutePolyline(
                        points: drive.pointsChronological,
                        mode: showSpeedHeatMap ? .heatMap : .solid,
                        lineWidth: 6
                    )
                }
                
                // Start marker
                if let start = drive.startCoordinate {
                    Annotation("Start", coordinate: start) {
                        Image(systemName: "play.circle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.green)
                            .background(Circle().fill(.white).padding(4))
                    }
                }
                
                // End marker
                if let end = drive.endCoordinate {
                    Annotation("End", coordinate: end) {
                        Image(systemName: "flag.checkered.circle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.red)
                            .background(Circle().fill(.white).padding(4))
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            .ignoresSafeArea()
            
            // Controls overlay
            VStack {
                // Top bar
                HStack {
                    // Close button
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .padding(12)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    
                    Spacer()
                    
                    // Drive info pill
                    HStack(spacing: 8) {
                        Text(drive.formattedDistance)
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text(drive.formattedDuration)
                    }
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    
                    Spacer()
                    
                    // Heat map toggle
                    Button {
                        showSpeedHeatMap.toggle()
                    } label: {
                        Image(systemName: showSpeedHeatMap ? "thermometer.high" : "thermometer.low")
                            .font(.headline)
                            .foregroundStyle(showSpeedHeatMap ? .orange : .primary)
                            .padding(12)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                
                Spacer()
                
                // Bottom controls
                HStack {
                    Spacer()
                    
                    // Recenter button
                    Button {
                        recenterMap()
                    } label: {
                        Image(systemName: "location.fill")
                            .font(.headline)
                            .foregroundStyle(.blue)
                            .padding(12)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
        }
        .onAppear {
            setupCamera()
        }
    }
    
    private func setupCamera() {
        guard let bounds = drive.routeBounds else { return }
        cameraPosition = .region(MKCoordinateRegion(center: bounds.center, span: bounds.span))
    }
    
    private func recenterMap() {
        withAnimation(.easeInOut(duration: 0.3)) {
            setupCamera()
        }
    }
}

// MARK: - Stat Card

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.blue)
            
            Text(value)
                .font(.title3)
                .fontWeight(.bold)
                .monospacedDigit()
            
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Detail Row

struct DetailRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            
            Spacer()
            
            Text(value)
                .fontWeight(.medium)
        }
    }
}

#Preview {
    NavigationStack {
        DriveDetailView(drive: Drive(
            startTime: Date().addingTimeInterval(-3600),
            endTime: Date(),
            distanceMeters: 8046.72
        ))
    }
}
