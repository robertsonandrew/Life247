//
//  TimerKind.swift
//  Life247
//
//  Created by Andrew Robertson on 1/14/26.
//

import Foundation

/// Timer types owned exclusively by the state machine.
/// Timers are cancelled on state exit and recreated on state entry.
enum TimerKind: String, Equatable {
    /// Verifies maybeDriving → driving transition
    /// Expires if speed threshold not sustained
    case maybeDrivingVerification
    
    /// Tracks how long vehicle has been stopped
    /// Triggers ended transition after threshold
    case stoppedTimeout
    
    /// Validates geofence arrival window (20-30s)
    case pendingArrival
    
    /// Safety fallback to end drives that exceed maximum duration
    case safetyEnd
}
