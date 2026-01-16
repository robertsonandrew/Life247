//
//  MemoryManager.swift
//  Life247
//
//  Created by Andrew Robertson on 1/16/26.
//

import Foundation
import UIKit
import OSLog

/// Minimal singleton that responds to iOS memory warnings.
/// Clears caches to reduce memory pressure. No smart heuristics.
final class MemoryManager {
    static let shared = MemoryManager()
    
    private let logger = Logger(subsystem: "com.life247", category: "Memory")
    
    private init() {
        // Observe memory warnings
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        logger.info("MemoryManager initialized")
    }
    
    @objc private func handleMemoryWarning() {
        logger.warning("⚠️ Memory warning received - clearing caches")
        
        // Clear geocoding cache
        Task {
            await GeocodingCache.shared.clearCache()
        }
        
        // Clear frequent stop analysis cache
        FrequentStopAnalyzer.clearCache()
    }
}
