//
//  LogCategory.swift
//  Life247
//
//  Created by Andrew Robertson on 1/16/26.
//

import Foundation
import SwiftUI

/// Category of log entry for the Drive Inspector timeline.
/// Each category has a distinct color for visual differentiation.
enum LogCategory: String, Codable, CaseIterable {
    case system     // App lifecycle, battery, authorization
    case motion     // CMMotionActivity changes
    case location   // GPS updates, pauses, accuracy
    case decision   // State machine transitions with reasons
    case anomaly    // Errors, gaps, unexpected behavior
    case trace      // Verbose diagnostics (optional)
    
    /// Color for timeline display
    var color: Color {
        switch self {
        case .system:   return .blue
        case .motion:   return .green
        case .location: return .yellow
        case .decision: return .purple
        case .anomaly:  return .red
        case .trace:    return .gray
        }
    }
    
    /// Emoji for compact display
    var emoji: String {
        switch self {
        case .system:   return "🟦"
        case .motion:   return "🟩"
        case .location: return "🟨"
        case .decision: return "🟪"
        case .anomaly:  return "🟥"
        case .trace:    return "⬜️"
        }
    }
    
    /// Human-readable label
    var label: String {
        switch self {
        case .system:   return "System"
        case .motion:   return "Motion"
        case .location: return "Location"
        case .decision: return "Decision"
        case .anomaly:  return "Anomaly"
        case .trace:    return "Trace"
        }
    }
}
