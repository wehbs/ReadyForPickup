//
//  SavedSearch.swift
//  ReadyForPickup
//

import Foundation

/// One saved search in the 2.0-style UI: a product at a store in one
/// country, with its own preferred models, nearby-store preference,
/// custom SKU and local-notification preference. Multiple searches are
/// persisted as Codable JSON in UserDefaults (key "savedSearches").
struct SavedSearch: Codable, Identifiable, Equatable {
    var id: UUID
    var productTypeRaw: String
    /// The store's country (Country.code). It decides the store list, the
    /// storefront requests go to and the part numbers watched.
    var countryCode: CountryCode
    var storeNumber: String
    var storeName: String?
    var includeNearby: Bool
    var preferredSKUs: [String]
    var onlyPreferred: Bool
    var notifyOnThisMac: Bool
    var notifyViaPushover: Bool
    var customSku: String
    var customSkuNickname: String

    init(id: UUID = UUID(),
         productType: ProductType,
         countryCode: CountryCode = "US",
         storeNumber: String,
         storeName: String? = nil,
         includeNearby: Bool = true,
         preferredSKUs: [String] = [],
         onlyPreferred: Bool = false,
         notifyOnThisMac: Bool = true,
         notifyViaPushover: Bool = true,
         customSku: String = "",
         customSkuNickname: String = "") {
        self.id = id
        self.productTypeRaw = productType.rawValue
        self.countryCode = countryCode
        self.storeNumber = storeNumber
        self.storeName = storeName
        self.includeNearby = includeNearby
        self.preferredSKUs = preferredSKUs
        self.onlyPreferred = onlyPreferred
        self.notifyOnThisMac = notifyOnThisMac
        self.notifyViaPushover = notifyViaPushover
        self.customSku = customSku
        self.customSkuNickname = customSkuNickname
    }

    private enum CodingKeys: String, CodingKey {
        case id, productTypeRaw, countryCode, storeNumber, storeName, includeNearby
        case preferredSKUs, onlyPreferred, notifyOnThisMac, notifyViaPushover
        case customSku, customSkuNickname
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        productTypeRaw = try c.decode(String.self, forKey: .productTypeRaw)
        // Added with per-search countries. Before then every search used
        // the app-wide country setting (its store list, storefront and
        // part numbers), so a search saved then gets that country, even
        // one the catalog doesn't have. SearchStore.load saves it.
        countryCode = try c.decodeIfPresent(String.self, forKey: .countryCode) ?? DefaultsVendor().storedCountryCode
        storeNumber = try c.decode(String.self, forKey: .storeNumber)
        storeName = try c.decodeIfPresent(String.self, forKey: .storeName)
        includeNearby = try c.decodeIfPresent(Bool.self, forKey: .includeNearby) ?? true
        preferredSKUs = try c.decodeIfPresent([String].self, forKey: .preferredSKUs) ?? []
        onlyPreferred = try c.decodeIfPresent(Bool.self, forKey: .onlyPreferred) ?? false
        notifyOnThisMac = try c.decodeIfPresent(Bool.self, forKey: .notifyOnThisMac) ?? true
        // Added after searches were already being saved; default on,
        // actual sending is still gated by app-wide Pushover config.
        notifyViaPushover = try c.decodeIfPresent(Bool.self, forKey: .notifyViaPushover) ?? true
        customSku = try c.decodeIfPresent(String.self, forKey: .customSku) ?? ""
        customSkuNickname = try c.decodeIfPresent(String.self, forKey: .customSkuNickname) ?? ""
    }

    /// Falls back to a current product if the saved type was retired.
    var productType: ProductType {
        get { ProductType(rawValue: productTypeRaw) ?? .iPhonePro18 }
        set { productTypeRaw = newValue.rawValue }
    }

    var customSkuData: (sku: String, nickname: String)? {
        let sku = customSku.trimmingCharacters(in: .whitespaces)
        guard sku.isEmpty == false else { return nil }
        let name = customSkuNickname.trimmingCharacters(in: .whitespaces)
        return (sku, name.isEmpty ? sku : name)
    }

    func isPreferred(_ part: PartAvailability) -> Bool {
        preferredSKUs.contains(part.partNumber) || customSkuData?.sku == part.partNumber
    }

    /// Whether a fetch made for `other` (an earlier copy) is still current
    /// for this search. A new country, product, store or results filter
    /// makes it stale (each of those edits starts its own fetch); other
    /// edits don't.
    func requestsSameInventory(as other: SavedSearch) -> Bool {
        countryCode == other.countryCode && productTypeRaw == other.productTypeRaw
            && storeNumber == other.storeNumber
            && includeNearby == other.includeNearby && onlyPreferred == other.onlyPreferred
    }
}

/// UserDefaults-backed store for saved searches.
enum SearchStore {
    private static let key = "savedSearches"

    static func load() -> [SavedSearch] {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([SavedSearch].self, from: data),
           decoded.isEmpty == false {
            // Saved now, so a search from before searches had countries
            // keeps the one it decoded with (see init(from:)) when the
            // default country, stored under the same key, changes.
            save(decoded)
            return decoded
        }
        let initial = [defaultSearch()]
        save(initial)
        return initial
    }

    static func save(_ searches: [SavedSearch]) {
        if let data = try? JSONEncoder().encode(searches) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// The first search of a fresh install, and the US store a new search
    /// starts at when no other search is in the US.
    static func defaultSearch() -> SavedSearch {
        SavedSearch(productType: .iPhonePro18, countryCode: "US", storeNumber: "R032", storeName: "SoHo")
    }
}
