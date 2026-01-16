//
//  HistoryTimeSpan.swift
//  Life247
//
//  Created by Andrew Robertson on 1/15/26.
//

import Foundation

/// Time span options for history overlay on the map.
enum HistoryTimeSpan: CaseIterable {
    case off
    case oneHour
    case sixHours
    case twelveHours
    case twentyFourHours
    
    var label: String {
        switch self {
        case .off: return "Off"
        case .oneHour: return "1h"
        case .sixHours: return "6h"
        case .twelveHours: return "12h"
        case .twentyFourHours: return "24h"
        }
    }
    
    /// Hours to look back, nil for off
    var hours: Int? {
        switch self {
        case .off: return nil
        case .oneHour: return 1
        case .sixHours: return 6
        case .twelveHours: return 12
        case .twentyFourHours: return 24
        }
    }
    
    /// Get the next time span in cycle
    var next: HistoryTimeSpan {
        let all = HistoryTimeSpan.allCases
        guard let index = all.firstIndex(of: self) else { return .off }
        let nextIndex = (index + 1) % all.count
        return all[nextIndex]
    }
    
    /// Window start date for query
    var windowStart: Date? {
        guard let hours else { return nil }
        return Date().addingTimeInterval(-Double(hours) * 3600)
    }
}
