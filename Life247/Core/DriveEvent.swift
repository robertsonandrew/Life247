//
//  DriveEvent.swift
//  Life247
//
//  Created by Andrew Robertson on 1/14/26.
//

import Foundation
import CoreLocation
import CoreMotion

/// Typed events that feed the DriveStateMachine.
/// All sensor inputs are converted to these events.
/// No direct callbacks are allowed to mutate state.
enum DriveEvent {
    /// CoreMotion detected automotive activity
    case motionAutomotive(confidence: CMMotionActivityConfidence)
    
    /// CoreMotion detected non-automotive activity (walking, stationary, etc.)
    case motionNotAutomotive
    
    /// New GPS location received
    case locationUpdate(CLLocation)
    
    /// Significant location change triggered (wakes app)
    case significantLocationChange
    
    /// CLVisit arrival detected
    case visitArrival
    
    /// CLVisit departure detected
    case visitDeparture
    
    /// A state machine timer expired
    case timerExpired(TimerKind)
}
