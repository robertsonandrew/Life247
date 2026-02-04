//
//  DriveLogEntry.swift
//  Life247
//
//  Created by Andrew Robertson on 1/16/26.
//

import Foundation
import SwiftData

/// Append-only log entry for a drive.
/// Used by the Drive Inspector to show the timeline of events.
/// This is the "flight recorder" that powers debugging.
@Model
final class DriveLogEntry {
    var id: UUID
    var timestamp: Date
    var categoryRaw: String         // LogCategory raw value (SwiftData workaround)
    var eventType: String           // e.g. "app_backgrounded", "motion_automotive"
    var message: String             // Human-readable summary
    var metadataJSON: String?       // JSON-encoded [String: String] for structured context
    
    /// Inverse relationship to Drive
    var drive: Drive?
    
    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        category: LogCategory,
        eventType: String,
        message: String,
        metadata: [String: String]? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.categoryRaw = category.rawValue
        self.eventType = eventType
        self.message = message
        
        if let metadata = metadata {
            self.metadataJSON = try? JSONEncoder().encode(metadata).base64EncodedString()
        }
    }
    
    // MARK: - Computed Properties
    
    var category: LogCategory {
        LogCategory(rawValue: categoryRaw) ?? .system
    }
    
    var metadata: [String: String]? {
        guard let json = metadataJSON,
              let data = Data(base64Encoded: json) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }
    
    /// Formatted timestamp for display (HH:mm:ss)
    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: timestamp)
    }
}
