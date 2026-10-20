//
//  ModelError.swift
//  ReadyForPickup
//
//  Created by Worth Baker on 10/25/22.
//

import Foundation

enum AppError: Swift.Error, LocalizedError {
    case invalidLocalModelStore
    case invalidProjectState
    case couldNotGenerateURL
    case noStoresFound
    case storeUnavailable
    case throttled(Int)
    case invalidStoreResponse
    case unexpectedJSONStructure
    case countryNotSupported
    case productNotSold
    case storeNotListed
    
    var errorDescription: String? {
        return errorMessage
    }
    
    var errorMessage: String {
        switch self {
        case .couldNotGenerateURL:
            return "ReadyForPickup failed to construct a valid URL for your search."
        case .countryNotSupported:
            return "ReadyForPickup doesn't watch stores in this search's country. Choose another country."
        case .productNotSold:
            return "ReadyForPickup has no models for this product in this search's country. Choose another product."
        case .storeNotListed:
            return "This search's store isn't listed for its country (it may have closed). Choose another store, or check the search's country."
        case .invalidStoreResponse, .unexpectedJSONStructure, .noStoresFound:
            return "Unexpected inventory data found. Please confirm that the selected store is valid for the selected country."
        case .storeUnavailable:
            return "Apple's fulfillment API returned an internal server error and is currently unavailable."
        case .throttled(let statusCode):
            return "Apple is throttling requests (HTTP \(statusCode)); retrying later."
        case .invalidLocalModelStore, .invalidProjectState:
            return "ReadyForPickup has invalid or corrupted local data."
        }
    }
}
