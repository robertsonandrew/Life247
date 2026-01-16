//
//  AppTab.swift
//  Life247
//
//  Created by Andrew Robertson on 1/15/26.
//

import Foundation

/// Navigation tabs for the app.
/// ContentView is the ONLY owner of selectedTab state.
enum AppTab: String, Hashable, CaseIterable {
    case map
    case history
    case settings
    
    var title: String {
        switch self {
        case .map: return "Map"
        case .history: return "History"
        case .settings: return "Settings"
        }
    }
    
    var icon: String {
        switch self {
        case .map: return "map.fill"
        case .history: return "clock.fill"
        case .settings: return "gearshape.fill"
        }
    }
}
