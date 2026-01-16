//
//  PermissionsView.swift
//  Life247
//
//  Created by Andrew Robertson on 1/14/26.
//

import SwiftUI
import CoreLocation

/// Onboarding view for requesting location and motion permissions.
struct PermissionsView: View {
    @ObservedObject var locationManager: LocationManager
    @ObservedObject var motionManager: MotionManager
    
    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            
            // App icon/logo area
            Image(systemName: "car.fill")
                .font(.system(size: 80))
                .foregroundStyle(.blue.gradient)
            
            Text("Life247")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Your Personal Drive Tracker")
                .font(.title3)
                .foregroundStyle(.secondary)
            
            Spacer()
            
            // Permission cards
            VStack(spacing: 16) {
                PermissionCard(
                    icon: "location.fill",
                    title: "Location Access",
                    description: "Required to track your drives in the background",
                    status: locationPermissionStatus,
                    action: {
                        locationManager.requestAuthorization()
                    }
                )
                
                PermissionCard(
                    icon: "figure.walk",
                    title: "Motion Access",
                    description: "Helps detect when you're driving",
                    status: motionManager.isAuthorized ? .granted : .required,
                    action: {
                        motionManager.startMonitoring()
                    }
                )
            }
            .padding(.horizontal)
            
            Spacer()
            
            // Continue button
            if allPermissionsGranted {
                Text("You're all set!")
                    .font(.headline)
                    .foregroundStyle(.green)
                    .padding()
            }
        }
        .padding()
    }
    
    private var locationPermissionStatus: PermissionStatus {
        switch locationManager.authorizationStatus {
        case .authorizedAlways:
            return .granted
        case .authorizedWhenInUse:
            return .partial
        case .denied, .restricted:
            return .denied
        default:
            return .required
        }
    }
    
    private var allPermissionsGranted: Bool {
        locationManager.hasAlwaysAuthorization && motionManager.isAuthorized
    }
}

// MARK: - Permission Status

enum PermissionStatus {
    case required
    case partial
    case granted
    case denied
}

// MARK: - Permission Card

struct PermissionCard: View {
    let icon: String
    let title: String
    let description: String
    let status: PermissionStatus
    let action: () -> Void
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(iconColor)
                .frame(width: 44, height: 44)
                .background(iconColor.opacity(0.15))
                .clipShape(Circle())
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            statusView
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    
    private var iconColor: Color {
        switch status {
        case .granted: return .green
        case .partial: return .orange
        case .denied: return .red
        case .required: return .blue
        }
    }
    
    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .granted:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title2)
            
        case .partial:
            Button(action: action) {
                Text("Upgrade")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.orange)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
            
        case .denied:
            Button(action: openSettings) {
                Text("Settings")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.red)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
            
        case .required:
            Button(action: action) {
                Text("Enable")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.blue)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
        }
    }
    
    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

#Preview {
    PermissionsView(
        locationManager: LocationManager(),
        motionManager: MotionManager()
    )
}
