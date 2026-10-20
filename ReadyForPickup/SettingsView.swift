//
//  SettingsView.swift
//  ReadyForPickup
//
//  Created by Worth Baker on 11/9/21.
//

import SwiftUI

/// Per-search settings now live in the main window's inspector
/// (2.0-style layout). This scene keeps only app-wide preferences.
struct SettingsView: View {
    @EnvironmentObject var model: ViewModel
    @EnvironmentObject var updater: UpdaterViewModel
    @AppStorage("preferredCountry") private var preferredCountry = "US"
    @AppStorage("preferredUpdateInterval") private var preferredUpdateInterval: Int = 5
    @State private var pushoverUserKey: String = PushoverSettings.userKey
    @State private var pushoverApiToken: String = PushoverSettings.apiToken
    @State private var isSendingTest = false

    var body: some View {
        Form {
            Text("Searches, countries, products, stores and notifications are configured per search in the main window's right-hand inspector.")
                .foregroundColor(.secondary)

            // Stored under the old app-wide setting's key (see DefaultsVendor).
            Picker("Default country", selection: $preferredCountry) {
                ForEach(Country.all) { country in
                    Text(country.name).tag(country.code)
                }
            }
            Text("New searches start in this country, at a store there. Each search's own country is set in the inspector.")
                .font(.caption).foregroundColor(.secondary)

            Picker("Auto-refresh every", selection: $preferredUpdateInterval) {
                Text("Off").tag(0)
                Text("5 minutes").tag(5)
                Text("10 minutes").tag(10)
                Text("15 minutes").tag(15)
                Text("30 minutes").tag(30)
            }
            .onChange(of: preferredUpdateInterval) { newValue in
                // Takes effect immediately; no relaunch needed. The
                // scheduler doubles this wait (up to 60 min) while
                // Apple is throttling requests.
                model.restartAutoRefresh(withMinutes: newValue)
            }
            Text("Searches refresh automatically, one after another, while the app is running - even with its window closed. To re-check now, use the toolbar refresh button or File > Refresh Selected Search (Cmd-R), or File > Refresh All Searches (Shift-Cmd-R); either also resets the schedule.")
                .font(.caption).foregroundColor(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Software Updates").font(.headline)
                Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
                CheckForUpdatesView(updater: updater)
                Text("Updates are downloaded from GitHub via Sparkle. Version 0.3.2 and earlier can't install updates: download 0.3.3 or later once from the Releases page.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Mac notifications").font(.headline)
                // On only when macOS allows them too; turning it on asks
                // macOS, or opens System Settings if the user said no there.
                Toggle("Enable Mac notifications", isOn: Binding(
                    get: { model.macNotificationsActive },
                    set: { on in Task { await model.setMacNotificationsEnabled(on) } }))
                Text(macNotificationsCaption)
                    .font(.caption).foregroundColor(.secondary)
                HStack {
                    if model.macNotificationsEnabled, model.macNotificationStatus == .denied {
                        Button("Open Notification Settings…") { NotificationManager.openSystemSettings() }
                    }
                    Button("Send test notification") {
                        Task { await model.sendTestMacNotification() }
                    }
                    .disabled(model.macNotificationsActive == false)
                }
                if let feedback = model.macNotificationFeedback {
                    Text(feedback).font(.caption)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Pushover (push to your phone)").font(.headline)
                Text("Pushover requires your own account and app token: install Pushover on your iPhone, register an application at pushover.net/apps, then paste your User Key and that app's API Token below. Keys are stored in your Mac's Keychain, never in the app.")
                    .font(.caption).foregroundColor(.secondary)

                Toggle("Enable Pushover notifications", isOn: Binding(
                    get: { model.pushoverEnabled },
                    set: { model.setPushoverEnabled($0) }))

                SecureField("Pushover User Key", text: $pushoverUserKey)
                    .onChange(of: pushoverUserKey) { PushoverSettings.userKey = $0; model.refreshPushoverState() }
                SecureField("Application API Token", text: $pushoverApiToken)
                    .onChange(of: pushoverApiToken) { PushoverSettings.apiToken = $0; model.refreshPushoverState() }

                HStack {
                    Button("Send test notification") {
                        isSendingTest = true
                        Task { await model.sendTestPushover(); isSendingTest = false }
                    }
                    .disabled(isSendingTest || pushoverUserKey.isEmpty || pushoverApiToken.isEmpty)
                    if isSendingTest { ProgressView().controlSize(.small) }
                }
                if pushoverUserKey.isEmpty || pushoverApiToken.isEmpty {
                    Text("Enter both keys to enable the test button. With invalid keys, Pushover's own error is shown here.")
                        .font(.caption).foregroundColor(.secondary)
                }
                if let feedback = model.pushoverFeedback {
                    Text(feedback).font(.caption)
                        .foregroundColor(feedback.hasPrefix("Test sent") ? .green : .red)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .task { await model.refreshMacNotificationStatus() }
        // Picks up a change made in System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshMacNotificationStatus() }
        }
    }

    private var macNotificationsCaption: String {
        if model.macNotificationsActive {
            return "On. Banners, sounds and Focus follow System Settings > Notifications > ReadyForPickup. Each search can also turn them off in the inspector."
        }
        if model.macNotificationsEnabled == false {
            return "Off: ReadyForPickup sends no Mac notifications."
        }
        switch model.macNotificationStatus {
        case .denied:
            return "macOS has notifications turned off for ReadyForPickup, and only System Settings can turn them back on: turn on Allow notifications there, then come back."
        default:
            return "Turn this on and macOS will ask whether ReadyForPickup may send notifications."
        }
    }
}
