//
//  AirplaneModeManager.swift
//  Life247
//
//  Created by Andrew Robertson on 1/14/26.
//

import Foundation
import SwiftUI
import Combine
import OSLog

/// Global manager for Airplane Mode (detection pause).
/// Only SettingsView may toggle this value; all other code reads only.
final class AirplaneModeManager: ObservableObject {
    static let shared = AirplaneModeManager()
    
    private let logger = Logger(subsystem: "com.life247", category: "AirplaneMode")
    
    /// Callback triggered when Airplane Mode is disabled (ON → OFF)
    /// Used by DriveStateMachine to reconcile stale state
    var onDisable: (() -> Void)?
    
    /// Internal backing storage
    @AppStorage("airplaneModeEnabled") private var _isEnabled: Bool = false
    
    /// Persistent toggle - disables all detection and background processing
    var isEnabled: Bool {
        get { _isEnabled }
        set {
            let wasEnabled = _isEnabled
            objectWillChange.send()
            _isEnabled = newValue
            
            if newValue {
                logger.info("[AIRPLANE] Enabled")
            } else {
                logger.info("[AIRPLANE] Disabled")
                
                // Trigger reconciliation when transitioning OFF
                if wasEnabled {
                    logger.info("[AIRPLANE] Triggering state reconciliation")
                    onDisable?()
                }
            }
        }
    }
    
    private init() {}
}

