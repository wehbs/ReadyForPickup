//
//  NotificationSender.swift
//  ReadyForPickup
//
//  Created by Worth Baker on 10/27/22.
//

import Foundation

struct NotificationSender {

    /// Local Mac notification only (this app has no text/email service).
    /// Sends when a preferred model (or custom SKU) is available.
    func sendNotificationIfNeeded(availableParts: [(FulfillmentStore, [PartAvailability])], search: SavedSearch) async {
        guard search.notifyOnThisMac else { return }
        let preferred = availableParts.flatMap { store, parts in
            parts.filter { search.isPreferred($0) }.map { (store, $0) }
        }
        guard preferred.isEmpty == false else { return }

        let summary = Dictionary(grouping: preferred, by: { $0.1.partName })
            .map { "\($0.key): \($0.value.count) found" }
            .sorted()
            .joined(separator: ", ")
        NotificationManager.shared.sendNotification(title: "Preferred Model Found!", body: summary)
    }
}
