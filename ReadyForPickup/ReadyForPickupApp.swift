//
//  ReadyForPickupApp.swift
//  ReadyForPickup
//
//  Created by Worth Baker on 11/8/21.
//

import SwiftUI

@main
struct ReadyForPickupApp: App {
    @StateObject var model: ViewModel
    @StateObject private var updater: UpdaterViewModel

    init() {
        _model = StateObject(wrappedValue: ViewModel())
        _updater = StateObject(wrappedValue: UpdaterViewModel())
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updater)
            }
            CommandGroup(replacing: .newItem) {
                Button("Refresh Selected Search") {
                    Task { await model.fetchSelected() }
                }
                .keyboardShortcut("r", modifiers: .command)
                Button("Refresh All Searches") {
                    Task { await model.fetchAllSearches() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
        
        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(updater)
        }
    }
}
