//
//  Notifications.swift
//  Life247
//
//  Created by Andrew Robertson on 1/17/26.
//

import Foundation

extension Notification.Name {
    /// Posted when a drive is finalized by the state machine.
    /// UserInfo contains key `NotificationKeys.driveId` with the Drive UUID string.
    static let driveEnded = Notification.Name("com.life247.driveEnded")

    /// Posted when a PlaceVisit is closed (departureTime set).
    /// UserInfo contains key `NotificationKeys.placeVisitId` with the PlaceVisit UUID string.
    static let placeVisitEnded = Notification.Name("com.life247.placeVisitEnded")
}

enum NotificationKeys {
    /// Key for passing the Drive object ID (UUID string) or object itself if valid
    static let driveId = "driveId"

    /// Key for passing the PlaceVisit object ID (UUID string)
    static let placeVisitId = "placeVisitId"
}
