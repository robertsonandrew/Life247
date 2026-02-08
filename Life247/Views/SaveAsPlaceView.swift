//
//  SaveAsPlaceView.swift
//  Life247
//
//  Created by Andrew Robertson on 1/15/26.
//

import SwiftUI
import SwiftData
import MapKit

/// Simplified Place creation flow with pre-filled coordinate.
struct SaveAsPlaceView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var syncService: DriveSyncService
    @Environment(\.dismiss) private var dismiss
    
    /// Initial coordinate (can be adjusted via map)
    let initialCoordinate: CLLocationCoordinate2D
    
    @State private var name = ""
    @State private var selectedIcon = "mappin.circle.fill"
    @State private var radius: Double = 100
    @State private var coordinate: CLLocationCoordinate2D
    
    init(coordinate: CLLocationCoordinate2D) {
        self.initialCoordinate = coordinate
        self._coordinate = State(initialValue: coordinate)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Name") {
                    TextField("Place name", text: $name)
                }
                
                Section("Icon") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(Place.commonIcons, id: \.icon) { item in
                                Button {
                                    selectedIcon = item.icon
                                } label: {
                                    VStack(spacing: 4) {
                                        Image(systemName: item.icon)
                                            .font(.title2)
                                            .foregroundStyle(selectedIcon == item.icon ? .blue : .secondary)
                                        Text(item.name)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(width: 60)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
                
            }
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(height: 240)
            
            InteractiveGeofenceMap(
                coordinate: $coordinate,
                radiusMeters: $radius,
                icon: selectedIcon
            )
        }
        .navigationTitle("Save as Place")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    savePlace()
                }
                .disabled(name.isEmpty)
            }
        }
    }
    
    private func savePlace() {
        let place = Place(
            name: name,
            coordinate: coordinate,
            radiusMeters: radius,
            icon: selectedIcon
        )
        
        modelContext.insert(place)
        
        // Sync to server
        Task {
            await syncService.syncPlace(place)
        }
        
        dismiss()
    }
}

#Preview {
    NavigationStack {
        SaveAsPlaceView(coordinate: CLLocationCoordinate2D(latitude: 36.0, longitude: -95.9))
    }
    .environmentObject(LocationManager())
    .modelContainer(for: Place.self, inMemory: true)
}
