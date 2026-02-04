//
//  PuckState.swift
//  Life247
//
//  Created by Andrew Robertson on 1/30/26.
//

import Foundation

/// Visual state of the navigation puck.
/// Used for hysteresis-based transitions between stopped/moving displays.
enum PuckState: Equatable {
    /// Stationary: Display as blue dot with compass bearing cone
    case stopped
    
    /// In motion: Display as directional arrow using GPS course
    case moving
}
