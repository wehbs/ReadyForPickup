//
//  Countries.swift
//  ReadyForPickup
//
//  Created by Worth Baker on 11/10/21.
//

import Foundation

/// A country whose Apple Stores can be watched. The list comes from
/// ProductCatalog.json (see SKUDataLoader), which only has countries whose
/// models were checked against that country's own pickup API.
struct Country: Hashable, Identifiable, Sendable {
    /// ISO 3166-1 alpha-2 code, e.g. "GB".
    let code: CountryCode
    /// English name, e.g. "United Kingdom".
    let name: String
    /// The country's key in Stores_LocalBootstrap.json, e.g. "en_GB".
    let locale: String
    /// Apple's storefront for the country, https://<storeHost>/<storePath>/
    /// (e.g. www.apple.com/uk/). The US and China mainland
    /// (www.apple.com.cn) have no path.
    let storeHost: String
    let storePath: String

    var id: CountryCode { code }

    /// The US first, then by English name. Empty only if the bundled
    /// catalog couldn't be read.
    static var all: [Country] { SKUDataLoader.shared.countries }

    static func with(code: CountryCode) -> Country? {
        all.first { $0.code == code }
    }

    /// A path on the country's storefront: "/uk/shop/buy-iphone/" for
    /// "shop/buy-iphone/" in the UK, "/shop/buy-iphone/" in the US.
    func storefrontPath(_ path: String) -> String {
        storePath.isEmpty ? "/\(path)" : "/\(storePath)/\(path)"
    }

    /// Apple's page for one model in this country's store, which redirects to
    /// the buy page with that configuration selected: /shop/product/MJQ34LL/A
    /// opens /shop/buy-iphone/iphone-18-pro/6.3-inch-display-256gb-black.
    func productPageURL(partNumber: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = storeHost
        components.path = storefrontPath("shop/product/\(partNumber)")
        return components.url
    }
}
