//
//  Store.swift
//  ReadyForPickup
//
//  Created by Worth Baker on 7/27/22.
//

import Foundation

/// A store as the pickup-message API reports it, with its parts'
/// availability (`RetailStore` is the bundled store-list entry).
struct FulfillmentStore: Equatable {
    let storeName: String
    let storeNumber: String
    let city: String
    let state: String?
    
    var locationDescription: String {
        return [city, state].compactMap { $0 }.joined(separator: ", ")
    }
    
    let partsAvailability: [PartAvailability]
}
