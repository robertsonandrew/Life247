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
    
    /// CoreMotion detected non-automotive activity (stationary, cycling, etc.)
    case motionNotAutomotive
    
    /// CoreMotion detected user is on foot (walking or running) - strong signal of drive end
    case motionOnFoot
    
    /// New GPS location received
    case locationUpdate(CLLocation)
    
    /// Significant location change triggered (wakes app)
    case significantLocationChange
    
    /// CLVisit arrival detected (contains timestamp + coordinate)
    case visitArrival(CLVisit)
    
    /// CLVisit departure detected (contains timestamp + coordinate)
    case visitDeparture(CLVisit)
    
    /// Geofence exit detected for a monitored region
    case geofenceExit(regionId: String)
    
    /// Geofence entry detected for a monitored region (arrived at saved place)
    case geofenceEntry(regionId: String)
    
    /// A state machine timer expired
    case timerExpired(TimerKind)
}
