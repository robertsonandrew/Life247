//
//  DriveQualityPolicy.swift
//  Life247
//
//  Created by Codex on 2/10/26.
//

import Foundation
import CoreLocation

/// Shared quality gates used by location filtering and drive recording.
/// Keep these centralized to prevent threshold drift across components.
enum DriveQualityPolicy {
    enum Accuracy {
        /// Maximum horizontal accuracy accepted for route recording and drive state logic.
        static let recordingMaxMeters: CLLocationAccuracy = 30.0

        /// Foreground/high-accuracy filter ceiling used by LocationFilter.
        static let filterHighAccuracyMaxMeters: CLLocationAccuracy = 25.0

        /// Relaxed background/low-power filter ceiling used by LocationFilter.
        static let filterLowPowerMaxMeters: CLLocationAccuracy = 100.0

        static func filterLimit(isHighAccuracyMode: Bool) -> CLLocationAccuracy {
            isHighAccuracyMode ? filterHighAccuracyMaxMeters : filterLowPowerMaxMeters
        }
    }
}
