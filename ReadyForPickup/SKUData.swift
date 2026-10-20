//
//  SKUData.swift
//  ReadyForPickup
//
//  Created by Worth Baker on 11/8/21.
//

import Foundation

/// One product's models in one country (see SKUDataLoader): the part
/// numbers to watch, in display order, and each one's name.
struct SKUData: Sendable {
    private let skuLookup: [String: String]
    let orderedSKUs: [String]

    init(orderedSKUs: [String], lookup: [String: String]) {
        self.orderedSKUs = orderedSKUs
        self.skuLookup = lookup
    }

    func productName(forSKU sku: String) -> String? {
        return skuLookup[sku]
    }
}
