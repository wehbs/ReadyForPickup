//
//  ProductType.swift
//  ReadyForPickup
//
//  Created by Worth Baker on 7/27/22.
//

import Foundation

/// Catalog focus (2026-10): only hero products Apple currently sells new —
/// all current iPhones and all current Macs. Discontinued 2022-era types
/// (iPhone 13/14, Watch Ultra gen 1, M1/M2 Macs, old iPads/AirPods/
/// Studio Display, etc.) were removed; a saved search naming a removed
/// case falls back to a current product (see SavedSearch.productType),
/// it does not crash.
enum ProductCategory: String, Codable, CaseIterable, Identifiable {
    var id: Self { self }

    case Mac, iPhone

    var products: [ProductType] {
        switch self {
        case .Mac:
            return [.MacBookNeo, .M5MacBookAir13, .M5MacBookAir15, .MacBookPro14, .MacBookPro16, .iMac, .MacMini, .MacStudio]
        case .iPhone:
            return [.iPhone16, .iPhone17, .iPhone17e, .iPhoneAir, .iPhoneDuo, .iPhonePro18, .iPhoneProMax18]
        }
    }
}

enum ProductType: String, Codable, CaseIterable, Identifiable {
    var id: Self { self }

    case MacBookNeo
    case M5MacBookAir13
    case M5MacBookAir15
    case MacBookPro14
    case MacBookPro16
    case iMac
    case MacMini
    case MacStudio

    case iPhone16
    case iPhone17
    case iPhone17e
    case iPhoneAir
    case iPhoneDuo
    case iPhonePro18
    case iPhoneProMax18

    var presentableName: String {
        switch self {
        case .MacBookNeo: return "MacBook Neo"
        case .M5MacBookAir13: return "M5 MacBook Air 13in"
        case .M5MacBookAir15: return "M5 MacBook Air 15in"
        case .MacBookPro14: return "MacBook Pro 14in"
        case .MacBookPro16: return "MacBook Pro 16in"
        case .iMac: return "iMac"
        case .MacMini: return "Mac mini"
        case .MacStudio: return "Mac Studio"
        case .iPhone16: return "iPhone 16"
        case .iPhone17: return "iPhone 17"
        case .iPhone17e: return "iPhone 17e"
        case .iPhoneAir: return "iPhone Air"
        case .iPhoneDuo: return "iPhone Duo"
        case .iPhonePro18: return "iPhone 18 Pro"
        case .iPhoneProMax18: return "iPhone 18 Pro Max"
        }
    }
}
