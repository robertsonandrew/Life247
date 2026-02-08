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
    @EnvironmentObject private var syncService: DriveSyncService
    @Query(sort: \Place.name) private var places: [Place]
    
    // Fetch drives for timeline analysis (last 60 days)
    @Query(filter: #Predicate<Drive> { $0.endTime != nil },
           sort: \Drive.startTime,
           order: .reverse)
    private var drives: [Drive]
    
    @State private var showingAddPlace = false
    @State private var suggestedPlaces: [FrequentStopCandidate] = []
    @State private var selectedSuggestion: FrequentStopCandidate?
    @State private var isLoadingSuggestions = true
    
    var body: some View {
        List {
            // Suggested Places section (only if we have suggestions)
            if !suggestedPlaces.isEmpty {
                Section {
                    ForEach(suggestedPlaces) { candidate in
                        Button {
                            selectedSuggestion = candidate
                        } label: {
                            SuggestedPlaceRowView(candidate: candidate)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Label("Suggested Places", systemImage: "lightbulb.fill")
                        .foregroundStyle(.yellow)
                } footer: {
                    Text("Locations you've visited on 3+ different days")
                }
            }
            
            // Saved Places section
            Section {
                if places.isEmpty {
                    ContentUnavailableView(
                        "No Saved Places",
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
            } header: {
                if !places.isEmpty {
                    Text("Saved Places")
                }
            }
        }
        .bottomBarPadding()
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
        .sheet(item: $selectedSuggestion) { candidate in
            NavigationStack {
                SaveAsPlaceView(coordinate: candidate.coordinate)
            }
        }
        .task {
            await loadSuggestedPlaces()
        }
        .onChange(of: places.count) { _, _ in
            // Refresh suggestions when places change (in case a suggestion was saved)
            Task { await loadSuggestedPlaces() }
        }
    }
    
    // MARK: - Data Loading
    
    private func loadSuggestedPlaces() async {
        isLoadingSuggestions = true
        
        // Build timeline from drives
        let timeline = await TimelineBuilder.buildTimeline(
            drives: Array(drives.prefix(200)), // Limit for performance
            places: places
        )
        
        // Extract stops
        let stops = timeline.compactMap { item -> InferredStop? in
            if case .stop(let stop) = item { return stop }
            return nil
        }
        
        // Analyze for frequent stops
        let result = FrequentStopAnalyzer.analyze(stops: stops, places: places)
        
        await MainActor.run {
            self.suggestedPlaces = result.candidates
            self.isLoadingSuggestions = false
        }
    }
    
    private func deletePlaces(at offsets: IndexSet) {
        for index in offsets {
            let place = places[index]
            let placeId = place.placeId
            modelContext.delete(place)
            
            // Sync deletion to server
            Task {
                await syncService.deletePlace(placeId)
            }
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
                
                Text("\(Int(place.clampedRadiusMeters))m radius")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Add Place View

struct AddPlaceView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var syncService: DriveSyncService
    @Environment(\.dismiss) private var dismiss
    
    @State private var name = ""
    @State private var selectedIcon = "mappin.circle.fill"
    @State private var radius: Double = 100
    @State private var coordinate: CLLocationCoordinate2D
    
    init() {
        // Default to current location if available, else Tulsa
        let manager = CLLocationManager()
        let defaultCoord = manager.location?.coordinate ?? CLLocationCoordinate2D(latitude: 36.0, longitude: -95.9)
        self._coordinate = State(initialValue: defaultCoord)
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

// MARK: - Edit Place View

struct EditPlaceView: View {
    @Bindable var place: Place
    @EnvironmentObject private var syncService: DriveSyncService
    @Environment(\.dismiss) private var dismiss
    
    /// Binding wrapper for the computed coordinate property
    private var coordinateBinding: Binding<CLLocationCoordinate2D> {
        Binding(
            get: { place.coordinate },
            set: { newCoord in
                place.latitude = newCoord.latitude
                place.longitude = newCoord.longitude
            }
        )
    }
    
    var body: some View {
        VStack(spacing: 0) {
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
                
            }
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(height: 200)
            
            InteractiveGeofenceMap(
                coordinate: coordinateBinding,
                radiusMeters: $place.radiusMeters,
                icon: place.icon
            )
        }
        .navigationTitle("Edit Place")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            // Sync changes when leaving the edit view
            Task {
                await syncService.syncPlace(place)
            }
        }
    }
}

#Preview {
    NavigationStack {
        PlacesView()
    }
    .environmentObject(LocationManager())
    .modelContainer(for: Place.self, inMemory: true)
}
