//
//  FulfillmentModel.swift
//  ReadyForPickup
//
//  Created by Worth Baker on 10/25/22.
//

import Foundation

actor FulfillmentModel {

    private var cachedStoreData: [String: StoreCountry] = [:]

    /// Stores by locale, from the bundled Stores_LocalBootstrap.json.
    /// Apple's remote store list (rsp-web/store-list) is gone (HTTP 404),
    /// so the maintainer refreshes the bundled copy instead
    /// (Scripts/update-store-list.py).
    func loadStoresByCountry() async throws -> [String: StoreCountry] {
        if cachedStoreData.isEmpty == false {
            return cachedStoreData
        }
        guard let url = Bundle.main.url(forResource: "Stores_LocalBootstrap", withExtension: "json") else {
            throw AppError.invalidProjectState
        }
        let data = try Data(contentsOf: url)
        cachedStoreData = try JSONDecoder().decode(StoreBootstrap.self, from: data).countryData
        return cachedStoreData
    }

    /// The bundled stores in `country`, in file order.
    func stores(in country: Country) async throws -> [RetailStore] {
        let byLocale = try await loadStoresByCountry()
        guard let stores = byLocale[country.locale]?.stores else {
            throw AppError.invalidProjectState
        }
        return stores
    }

    /// Fetches inventory for one saved search against its country's
    /// pickup endpoint. Requests are chunked at 20 parts (Apple's cap)
    /// and merged by store.
    func fetchInventory(for search: SavedSearch) async throws -> [(FulfillmentStore, [PartAvailability])] {
        guard let country = Country.with(code: search.countryCode) else {
            // No countries at all: ProductCatalog.json couldn't be read.
            throw Country.all.isEmpty ? AppError.invalidLocalModelStore : AppError.countryNotSupported
        }
        guard let skuData = SKUDataLoader.shared.skuData(for: search.productType, in: country.code) else {
            throw AppError.productNotSold
        }

        var allSkus = skuData.orderedSKUs
        if let custom = search.customSkuData, allSkus.contains(custom.sku) == false {
            allSkus.append(custom.sku)
        }

        let location = try await pickupLocation(for: search, in: country)
        let filter: Set<String>? = search.onlyPreferred
            ? Set(search.preferredSKUs).union(search.customSkuData.map { [$0.sku] } ?? [])
            : nil

        var merged: [String: FulfillmentStore] = [:]
        var order: [String] = []
        for chunkStart in stride(from: 0, to: allSkus.count, by: 20) {
            let chunk = Array(allSkus[chunkStart..<min(chunkStart + 20, allSkus.count)])
            let stores = try await fetchChunk(skus: chunk, location: location, country: country, skuData: skuData, search: search)
            for store in stores {
                if let existing = merged[store.storeNumber] {
                    let parts = existing.partsAvailability + store.partsAvailability.filter { new in
                        existing.partsAvailability.contains(where: { $0.partNumber == new.partNumber }) == false
                    }
                    merged[store.storeNumber] = FulfillmentStore(storeName: existing.storeName, storeNumber: existing.storeNumber, city: existing.city, state: existing.state, partsAvailability: parts)
                } else {
                    merged[store.storeNumber] = store
                    order.append(store.storeNumber)
                }
            }
        }

        let collected = order.compactMap { merged[$0] }
        return parseAvailableModels(from: collected, filterForModels: filter, search: search)
    }

    private func fetchChunk(skus: [String], location: String, country: Country, skuData: SKUData, search: SavedSearch) async throws -> [FulfillmentStore] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = country.storeHost
        components.path = country.storefrontPath("shop/retail/pickup-message")
        var items: [URLQueryItem] = [URLQueryItem(name: "pl", value: "true"), URLQueryItem(name: "location", value: location)]
        for (i, sku) in skus.enumerated() where sku.isEmpty == false {
            items.append(URLQueryItem(name: "parts.\(i)", value: sku))
        }
        components.queryItems = items

        guard let url = components.url else { throw AppError.couldNotGenerateURL }
        var request = URLRequest(url: url)
        // The storefront's own buy page, as Scripts/update-catalog.py sends
        // when it checks the catalog.
        request.addValue("https://\(country.storeHost)\(country.storefrontPath("shop/buy-iphone/"))", forHTTPHeaderField: "Referer")

        let (data, response) = try await URLSession.shared.data(for: request)
        return try parseStoreResponse(data, response: response as? HTTPURLResponse, skuData: skuData, search: search)
    }

    /// pickup-message takes a city / postal-code `location`, not an
    /// R### store number. Resolve it from the country's store list; a
    /// store that isn't listed (e.g. closed) has no location to send,
    /// except one in closedStoreLocations for a search that includes
    /// nearby stores (they are all it can find).
    private func pickupLocation(for search: SavedSearch, in country: Country) async throws -> String {
        guard let store = try await stores(in: country).first(where: { $0.storeNumber == search.storeNumber }) else {
            if search.includeNearby, let location = Self.closedStoreLocations[country.locale]?[search.storeNumber] {
                return location
            }
            throw AppError.storeNotListed
        }
        if let postal = store.address.postalCode, postal.isEmpty == false { return postal }
        return store.address.cityStateDisplay
    }

    /// Stores the 2026-10 store-list refresh dropped (closed) in countries
    /// searches could be saved in before it, by locale, with the postal
    /// code those searches sent.
    private static let closedStoreLocations: [String: [String: String]] = [
        "en_AU": ["R458": "2077"],
        "en_GB": ["R252": "BS1 3BZ"],
        "en_US": ["R052": "95014", "R063": "21204", "R141": "60062", "R198": "96815",
                  "R218": "48038", "R285": "92025", "R463": "28216", "R629": "06611"],
    ]

    private func parseStoreResponse(_ responseData: Data?, response: HTTPURLResponse?, skuData: SKUData, search: SavedSearch) throws -> [FulfillmentStore] {
        guard let responseData = responseData else {
            throw errorForStatusCode(response?.statusCode) ?? AppError.invalidStoreResponse
        }
        if let code = response?.statusCode, code >= 400 {
            // 541 is Apple's anti-bot/rate-limit page, 429 is standard.
            if code == 429 || code == 541 { throw AppError.throttled(code) }
            throw errorForStatusCode(code) ?? AppError.invalidStoreResponse
        }
        guard let json = try? JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any],
              let body = json["body"] as? [String: Any] else {
            throw AppError.unexpectedJSONStructure
        }

        // Current shape: body.stores[]. Legacy: body.content.pickupMessage.stores[].
        // No stores + errorMessage (e.g. "Product(s) Invalid or not
        // buyable" for a retired product) -> honest no-stores error.
        let storeList: [[String: Any]]
        if let stores = body["stores"] as? [[String: Any]] {
            storeList = stores
        } else if let content = body["content"] as? [String: Any],
                  let pickupMessage = content["pickupMessage"] as? [String: Any],
                  let stores = pickupMessage["stores"] as? [[String: Any]] {
            storeList = stores
        } else {
            throw AppError.noStoresFound
        }

        return storeList.compactMap { storeJSON in
            guard let name = storeJSON["storeName"] as? String,
                  let number = storeJSON["storeNumber"] as? String,
                  let city = storeJSON["city"] as? String else { return nil }
            let state = storeJSON["state"] as? String
            guard let partsAvailability = storeJSON["partsAvailability"] as? [String: [String: Any]] else { return nil }

            let parsedParts: [PartAvailability] = partsAvailability.values.compactMap { part in
                guard let partNumber = part["partNumber"] as? String,
                      let availabilityString = part["pickupDisplay"] as? String,
                      // "default" = pre-order / check-back: not in stock.
                      let availability = PartAvailability.PickupAvailability(rawValue: availabilityString == "default" ? "unavailable" : availabilityString)
                else { return nil }

                let productName: String
                if let name = skuData.productName(forSKU: partNumber) {
                    productName = name
                } else if let custom = search.customSkuData, partNumber == custom.sku {
                    productName = custom.nickname
                } else {
                    productName = partNumber
                }
                return PartAvailability(partNumber: partNumber, partName: productName, availability: availability)
            }
            return FulfillmentStore(storeName: name, storeNumber: number, city: city, state: state, partsAvailability: parsedParts)
        }
    }

    private func parseAvailableModels(from stores: [FulfillmentStore], filterForModels: Set<String>?, search: SavedSearch) -> [(FulfillmentStore, [PartAvailability])] {
        // The search's own store first, the rest in the order Apple sent.
        let own = stores.filter { $0.storeNumber == search.storeNumber }
        let scoped = search.includeNearby ? own + stores.filter { $0.storeNumber != search.storeNumber } : own
        return scoped
            .compactMap { store in
                let rv = store.partsAvailability.filter { part in
                    guard part.availability == .available else { return false }
                    if let filter = filterForModels, filter.contains(part.partNumber) == false { return false }
                    return true
                }
                return rv.isEmpty ? nil : (store, rv)
            }
    }

    private func errorForStatusCode(_ statusCode: Int?) -> AppError? {
        guard let statusCode else { return nil }
        switch statusCode {
        case 429, 541: return .throttled(statusCode)
        case 500...599: return .storeUnavailable
        default: return nil
        }
    }
}
