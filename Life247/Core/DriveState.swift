//
//  DriveState.swift
//  Life247
//
//  Created by Andrew Robertson on 1/14/26.
//

import Foundation

/// The closed set of drive states.
/// No additional states allowed without updating the transition table.
enum DriveState: String, Codable, Equatable {
    /// No active drive, low-power location monitoring only
    case idle
    
    /// Potential drive detected, verification window active
    /// No Drive object persisted yet
    case maybeDriving
    
    /// Active drive in progress, high-accuracy GPS enabled
    /// Drive object exists in persistence
    case driving
    
    /// Drive active but speed ≈ 0, GPS still running
    /// Could transition back to driving or end
    case stopped
    
    /// Drive finalized, no GPS recording
    /// Drive object has been saved with endTime
    case ended
}
