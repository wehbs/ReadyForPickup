//
//  PushoverClient.swift
//  ReadyForPickup
//

import Foundation
import Security

/// App-wide Pushover configuration.
/// - Enable flag: UserDefaults (`pushoverEnabled`, not a secret).
/// - User Key + Application API Token: macOS Keychain generic
///   passwords (NOT UserDefaults). Per Pushover's licensing guidance
///   for redistributed apps, every user registers their OWN
///   application at pushover.net/apps and pastes their own token -
///   no token is embedded in or shipped with this app.
enum PushoverSettings {
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "pushoverEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "pushoverEnabled") }
    }

    static var userKey: String {
        get { KeychainStore.string(account: "userKey") ?? "" }
        set { KeychainStore.set(newValue, account: "userKey") }
    }

    static var apiToken: String {
        get { KeychainStore.string(account: "apiToken") ?? "" }
        set { KeychainStore.set(newValue, account: "apiToken") }
    }

    /// Ready to send: enabled AND both keys present.
    static var isConfigured: Bool {
        isEnabled && userKey.isEmpty == false && apiToken.isEmpty == false
    }
}

/// Minimal Keychain generic-password storage.
enum KeychainStore {
    private static let service = "com.wehbs.ReadyForPickup.pushover"

    static func string(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, account: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            SecItemDelete(baseQuery(account: account) as CFDictionary)
            return
        }
        let data = Data(trimmed.utf8)
        let status = SecItemUpdate(baseQuery(account: account) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery(account: account)
            query[kSecValueData as String] = data
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

enum PushoverError: LocalizedError {
    case notConfigured
    case server(statusCode: Int, errors: [String])
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Pushover is not configured: enable it and enter your User Key and Application API Token in Settings."
        case .server(let statusCode, let errors):
            return "Pushover returned HTTP \(statusCode): \(errors.joined(separator: "; "))"
        case .invalidResponse:
            return "Pushover returned an unexpected response."
        }
    }
}

/// Single-attempt Pushover sender (no retry loop).
struct PushoverClient {
    /// `url` is shown under the message as a link titled `urlTitle`.
    static func send(title: String, message: String, url: URL? = nil, urlTitle: String? = nil) async throws {
        guard PushoverSettings.isConfigured else { throw PushoverError.notConfigured }

        // Pushover message limit is 1024 characters.
        let body = String(message.prefix(1000))
        let truncated = body.count < message.count ? body + "…" : body

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "token", value: PushoverSettings.apiToken),
            URLQueryItem(name: "user", value: PushoverSettings.userKey),
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "message", value: truncated),
            URLQueryItem(name: "priority", value: "0")
        ]
        if let url {
            components.queryItems?.append(URLQueryItem(name: "url", value: url.absoluteString))
            // Pushover allows 100 characters of link title.
            if let urlTitle { components.queryItems?.append(URLQueryItem(name: "url_title", value: String(urlTitle.prefix(100)))) }
        }

        var request = URLRequest(url: URL(string: "https://api.pushover.net/1/messages.json")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PushoverError.invalidResponse }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if http.statusCode == 200, (json?["status"] as? Int) == 1 {
            return
        }
        throw PushoverError.server(statusCode: http.statusCode,
                                   errors: (json?["errors"] as? [String]) ?? ["unknown error"])
    }

    /// Builds the stock-alert message from newly-available parts.
    /// The link goes to the first listed model's page in Apple's store (a
    /// Pushover message holds one link).
    static func stockMessage(for search: SavedSearch, parts: [(FulfillmentStore, [PartAvailability])])
        -> (title: String, message: String, url: URL?, urlTitle: String?) {
        var lines: [String] = []
        var first: PartAvailability?
        for (store, storeParts) in parts {
            for part in storeParts.sorted(by: { $0.partName < $1.partName }) {
                if first == nil { first = part }
                lines.append("\(part.partName) — \(store.storeName), \(store.locationDescription)")
            }
        }
        let url = first.flatMap { Country.with(code: search.countryCode)?.productPageURL(partNumber: $0.partNumber) }
        return ("ReadyForPickup: \(search.productType.presentableName) in stock",
                lines.joined(separator: "\n"),
                url, first.map { "View \($0.partName) at Apple" })
    }
}
