//
//  DriveMigrationHelper.swift
//  Life247
//
//  Created by Andrew Robertson on 1/31/26.
//

import Foundation
import SwiftData
import OSLog

/// One-time migration helper to populate cached computed values for existing drives.
/// This runs at app launch and updates drives that were created before caching was added.
struct DriveMigrationHelper {
    private static let logger = Logger(subsystem: "com.life247", category: "DriveMigration")
    
    /// UserDefaults key to track if migration has been completed
    private static let migrationCompletedKey = "DriveMigration_CachedMaxSpeedMPH_Completed"
    
    /// Check if migration is needed
    static var needsMigration: Bool {
        !UserDefaults.standard.bool(forKey: migrationCompletedKey)
    }
    
    /// Migrate existing drives to populate cachedMaxSpeedMPH.
    /// Only runs once per app installation.
    /// - Parameter modelContext: The SwiftData model context
    @MainActor
    static func migrateIfNeeded(modelContext: ModelContext) async {
        guard needsMigration else {
            logger.debug("Migration already completed, skipping")
            return
        }
        
        logger.info("Starting drive migration for cachedMaxSpeedMPH...")
        
        // Fetch all completed drives that need migration
        let descriptor = FetchDescriptor<Drive>(
            predicate: #Predicate { $0.endTime != nil && $0.cachedMaxSpeedMPH == 0 }
        )
        
        do {
            let drivesToMigrate = try modelContext.fetch(descriptor)
            
            guard !drivesToMigrate.isEmpty else {
                logger.info("No drives need migration")
                markMigrationCompleted()
                return
            }
            
            logger.info("Migrating \(drivesToMigrate.count) drives...")
            
            var migratedCount = 0
            for drive in drivesToMigrate {
                // Compute and cache max speed
                let maxSpeed = drive.points.map { $0.speedMPH }.max() ?? 0
                drive.cachedMaxSpeedMPH = maxSpeed
                migratedCount += 1
                
                // Log progress every 10 drives
                if migratedCount % 10 == 0 {
                    logger.debug("Migrated \(migratedCount)/\(drivesToMigrate.count) drives")
                }
            }
            
            try modelContext.save()
            
            logger.info("Migration complete: \(migratedCount) drives updated")
            markMigrationCompleted()
            
        } catch {
            logger.error("Migration failed: \(error.localizedDescription)")
            // Don't mark as completed so it retries next launch
        }
    }
    
    private static func markMigrationCompleted() {
        UserDefaults.standard.set(true, forKey: migrationCompletedKey)
    }
    
    /// Force re-migration (for debugging/testing)
    static func resetMigrationState() {
        UserDefaults.standard.removeObject(forKey: migrationCompletedKey)
    }
}
