//
//  Updater.swift
//  ReadyForPickup
//
//  Sparkle 2.x updater wiring. The private EdDSA key lives only in
//  the login Keychain (created by Sparkle's generate_keys tool);
//  only SUPublicEDKey is embedded in the app (see project settings).
//

import Combine
import Sparkle
import SwiftUI

@MainActor
final class UpdaterViewModel: ObservableObject {
    let updaterController: SPUStandardUpdaterController

    @Published var canCheckForUpdates = false
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            updaterController.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    init() {
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        automaticallyChecksForUpdates = updaterController.updater.automaticallyChecksForUpdates
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject var updater: UpdaterViewModel

    var body: some View {
        Button("Check for Updates\u{2026}") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
    }
}
