//
//  PlacesView.swift
//  Life247
//
//  Created by Andrew Robertson on 1/15/26.
//

import SwiftUI
import SwiftData
import MapKit

/// View for managing user-defined Places.
struct PlacesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Place.name) private var places: [Place]
    
    @State private var showingAddPlace = false
    
    var body: some View {
        List {
            if places.isEmpty {
                ContentUnavailableView(
                    "No Places",
                    systemImage: "mappin.slash",
                    description: Text("Add places like Home or Work to enhance your timeline")
                )
            } else {
                ForEach(places) { place in
                    NavigationLink {
                        EditPlaceView(place: place)
                    } label: {
                        PlaceRowView(place: place)
                    }
                }
                .onDelete(perform: deletePlaces)
            }
        }
        .contentMargins(.bottom, 100, for: .scrollContent)
        .navigationTitle("Places")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAddPlace = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddPlace) {
            NavigationStack {
                AddPlaceView()
            }
        }
    }
    
    private func deletePlaces(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(places[index])
        }
    }
}

// MARK: - Place Row

struct PlaceRowView: View {
    let place: Place
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: place.icon)
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 40)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name)
                    .font(.headline)
                
                Text("\(Int(place.radiusMeters))m radius")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Add Place View

struct AddPlaceView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    @State private var name = ""
    @State private var selectedIcon = "mappin.circle.fill"
    @State private var radius: Double = 100
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 36.0, longitude: -95.9),
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
    )
    @State private var markerPosition: CLLocationCoordinate2D?
    
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
                if markerPosition != nil {
                    Map(coordinateRegion: $region, annotationItems: markerAnnotations) { item in
                        MapAnnotation(coordinate: item.coordinate) {
                            Circle()
                                .fill(.blue.opacity(0.3))
                                .frame(width: radiusInPoints, height: radiusInPoints)
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
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Text("Tap below to use your current location")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(height: 100)
                        .frame(maxWidth: .infinity)
                }
                
                Button {
                    useCurrentLocation()
                } label: {
                    Label("Use Current Location", systemImage: "location.fill")
                }
            }
        }
        .navigationTitle("Add Place")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    savePlace()
                }
                .disabled(name.isEmpty || markerPosition == nil)
            }
        }
    }
    
    private var markerAnnotations: [MarkerAnnotation] {
        guard let position = markerPosition else { return [] }
        return [MarkerAnnotation(coordinate: position)]
    }
    
    private var radiusInPoints: CGFloat {
        // Approximate conversion (varies with zoom)
        CGFloat(radius / 5)
    }
    
    private func useCurrentLocation() {
        let manager = CLLocationManager()
        if let location = manager.location {
            markerPosition = location.coordinate
            region = MKCoordinateRegion(
                center: location.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
            )
        }
    }
    
    private func savePlace() {
        guard let position = markerPosition else { return }
        
        let place = Place(
            name: name,
            coordinate: position,
            radiusMeters: radius,
            icon: selectedIcon
        )
        
        modelContext.insert(place)
        dismiss()
    }
}

struct MarkerAnnotation: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
}

// MARK: - Edit Place View

struct EditPlaceView: View {
    @Bindable var place: Place
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        Form {
            Section("Name") {
                TextField("Place name", text: $place.name)
            }
            
            Section("Icon") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(Place.commonIcons, id: \.icon) { item in
                            Button {
                                place.icon = item.icon
                            } label: {
                                Image(systemName: item.icon)
                                    .font(.title2)
                                    .foregroundStyle(place.icon == item.icon ? .blue : .secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            
            Section("Radius") {
                Picker("Radius", selection: $place.radiusMeters) {
                    Text("50m").tag(50.0)
                    Text("100m").tag(100.0)
                    Text("250m").tag(250.0)
                }
                .pickerStyle(.segmented)
            }
            
            Section("Location") {
                Map {
                    Annotation(place.name, coordinate: place.coordinate) {
                        Image(systemName: place.icon)
                            .foregroundStyle(.blue)
                    }
                }
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .navigationTitle("Edit Place")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        PlacesView()
    }
    .modelContainer(for: Place.self, inMemory: true)
}
