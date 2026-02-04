//
//  PlaceVisitUploadDTO.swift
//  Life247
//
//  Created by Andrew Robertson on 1/18/26.
//

import Foundation
import UIKit

/// Codable DTO for uploading place dwell sessions to the self-hosted server.
struct PlaceVisitUploadDTO: Codable {
    let visitId: String
    let deviceId: String

    // Timing
    let arrivalTime: String // ISO8601
    let departureTime: String // ISO8601
    let durationSeconds: Double

    // Place snapshot
    let placeName: String
    let placeIcon: String
    let placeRadiusMeters: Double
    let placeLatitude: Double
    let placeLongitude: Double

    // Observed coordinate (visit coordinate)
    let latitude: Double
    let longitude: Double

    // Source
    let source: String

    // System context
    let deviceModel: String?
    let iosVersion: String?
    let appVersion: String?

    init(from visit: PlaceVisit) {
        self.visitId = visit.id.uuidString
        self.deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let dep = visit.departureTime ?? Date()
        self.arrivalTime = formatter.string(from: visit.arrivalTime)
        self.departureTime = formatter.string(from: dep)
        self.durationSeconds = dep.timeIntervalSince(visit.arrivalTime)

        self.placeName = visit.placeName
        self.placeIcon = visit.placeIcon
        self.placeRadiusMeters = visit.placeRadiusMeters
        self.placeLatitude = visit.placeLatitude
        self.placeLongitude = visit.placeLongitude

        self.latitude = visit.latitude
        self.longitude = visit.longitude

        self.source = visit.source

        self.deviceModel = PlaceVisitUploadDTO.deviceModelIdentifier
        self.iosVersion = ProcessInfo.processInfo.operatingSystemVersionString
        self.appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    private static var deviceModelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        return machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
    }
}

extension PlaceVisitUploadDTO {
    func toJSONData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
