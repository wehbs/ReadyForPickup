//
//  DefaultsVendor.swift
//  ReadyForPickup
//
//  Created by Worth Baker on 10/25/22.
//

import Foundation

struct DefaultsVendor {

    /// The country stored under the key of the app-wide country setting
    /// that 0.3.4 and earlier used for every search, and that saved the
    /// United Kingdom as "UK". Codes the catalog doesn't have are kept.
    var storedCountryCode: CountryCode {
        let stored = UserDefaults.standard.string(forKey: "preferredCountry") ?? "US"
        return stored == "UK" ? "GB" : stored
    }

    /// The country new searches start in (Settings): the stored country,
    /// or the US if the catalog doesn't have it.
    var defaultCountryCode: CountryCode {
        let code = storedCountryCode
        return Country.with(code: code) == nil ? "US" : code
    }
}
