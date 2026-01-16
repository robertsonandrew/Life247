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
    @Environment(\.dismiss) private var dismiss
    
    let coordinate: CLLocationCoordinate2D
    
    @State private var name = ""
    @State private var selectedIcon = "mappin.circle.fill"
    @State private var radius: Double = 100
    
    private let radiusPresets: [Double] = [50, 100, 250]
    
    var body: some View {
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
            
            Section("Radius") {
                Picker("Radius", selection: $radius) {
                    ForEach(radiusPresets, id: \.self) { preset in
                        Text("\(Int(preset))m").tag(preset)
                    }
                }
                .pickerStyle(.segmented)
            }
            
            Section("Location") {
                Map {
                    Annotation("", coordinate: coordinate) {
                        Circle()
                            .fill(.blue.opacity(0.3))
                            .frame(width: CGFloat(radius / 5), height: CGFloat(radius / 5))
                            .overlay(
                                Circle()
                                    .stroke(.blue, lineWidth: 2)
                            )
                            .overlay(
                                Image(systemName: selectedIcon)
                                    .foregroundStyle(.blue)
                            )
                    }
                }
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
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
        dismiss()
    }
}

#Preview {
    NavigationStack {
        SaveAsPlaceView(coordinate: CLLocationCoordinate2D(latitude: 36.0, longitude: -95.9))
    }
    .modelContainer(for: Place.self, inMemory: true)
}
