//
//  ModelLoader.swift
//  ReadyForPickup
//
//  Created by Worth Baker on 10/25/22.
//

import Foundation
import os

private let logger = Logger(subsystem: "com.wehbs.ReadyForPickup", category: "Catalog")

/// The supported countries and the models watched in each, read once from
/// the bundled ProductCatalog.json. Scripts/update-catalog.py writes that
/// file: every SKU in it was found in its country's own pickup API, and
/// Macs are the standard configurations (build-to-order ones have no
/// pickup part number). Countries and products it doesn't list aren't
/// offered.
struct SKUDataLoader: Sendable {

    static let shared = SKUDataLoader()

    /// The US first, then by English name (the file's order).
    let countries: [Country]
    private let skuData: [CountryCode: [ProductType: SKUData]]

    private init() {
        let loaded: (countries: [Country], skuData: [CountryCode: [ProductType: SKUData]])
        do {
            loaded = try Self.load()
        } catch {
            logger.error("Couldn't read ProductCatalog.json: \(error.localizedDescription, privacy: .public)")
            loaded = ([], [:])
        }
        countries = loaded.countries
        skuData = loaded.skuData
    }

    /// The products sold in `code`'s country, in ProductType.allCases order.
    func productTypes(in code: CountryCode) -> [ProductType] {
        ProductType.allCases.filter { skuData[code]?[$0] != nil }
    }

    /// Nil when the country doesn't sell the product.
    func skuData(for productType: ProductType, in code: CountryCode) -> SKUData? {
        skuData[code]?[productType]
    }

    private static func load() throws -> (countries: [Country], skuData: [CountryCode: [ProductType: SKUData]]) {
        guard let url = Bundle.main.url(forResource: "ProductCatalog", withExtension: "json") else {
            throw AppError.invalidProjectState
        }
        let catalog = try JSONDecoder().decode(CatalogFile.self, from: Data(contentsOf: url))

        var countries: [Country] = []
        var skuData: [CountryCode: [ProductType: SKUData]] = [:]
        for entry in catalog.countries where skuData[entry.code] == nil {
            var products: [ProductType: SKUData] = [:]
            // Product types this build doesn't know are skipped.
            for (rawValue, models) in entry.products {
                guard let productType = ProductType(rawValue: rawValue) else { continue }
                var ordered: [String] = []
                var names: [String: String] = [:]
                for model in models where names[model.sku] == nil {
                    ordered.append(model.sku)
                    names[model.sku] = model.name
                }
                if ordered.isEmpty == false {
                    products[productType] = SKUData(orderedSKUs: ordered, lookup: names)
                }
            }
            guard products.isEmpty == false else { continue }
            countries.append(Country(code: entry.code, name: entry.name, locale: entry.locale,
                                     storeHost: entry.storeHost, storePath: entry.storePath))
            skuData[entry.code] = products
        }
        return (countries, skuData)
    }
}

/// ProductCatalog.json's shape (see Scripts/update-catalog.py).
private struct CatalogFile: Decodable {
    struct Entry: Decodable {
        let code: CountryCode
        let name: String
        let locale: String
        let storeHost: String
        let storePath: String
        /// ProductType raw value -> its models, in display order.
        let products: [String: [Model]]
    }

    struct Model: Decodable {
        let sku: String
        let name: String
    }

    let countries: [Entry]
}
