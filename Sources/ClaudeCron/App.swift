import AppKit
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // First-launch position for the status item: close to the clock, so it
        // does not land in the notch's blind spot on a crowded menu bar. A user
        // who drags it elsewhere overrides this - registered defaults lose to
        // anything macOS later persists for the item.
        UserDefaults.standard.register(defaults: [
            "NSStatusItem Preferred Position Item-0": 140.0,
        ])
        DockPresence.apply()

        // Launching an accessory app that is already running looks broken: the
        // Dock and Spotlight report success while nothing appears. Opening the
        // Manager on a user-initiated launch gives the click an outcome; a launch
        // by the system (login item) stays quiet.
        let userLaunched = notification
            .userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        if userLaunched, !Screenshots.isRequested {
            WindowRouter.shared.openManager()
        }
        Notifier.setup(delegate: self)
        if !Paths.isSandboxed, !UserDefaults.standard.bool(forKey: "didOfferLoginItem") {
            UserDefaults.standard.set(true, forKey: "didOfferLoginItem")
            try? LoginItem.set(true)
        }
        Screenshots.runIfRequested()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let jobID = info["jobID"] as? String else { return }
        let runID = (info["runID"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        await MainActor.run {
            WindowRouter.shared.openManager(select: jobID, tab: .runs, runID: runID)
        }
    }

    /// Clicking the Dock icon or launching the app again.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        WindowRouter.shared.openManager()
        return true
    }

    /// Closing the Manager leaves the app in the menu bar; jobs keep their
    /// schedule either way, but quitting on a closed window would be a surprise.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// Whether the app keeps a Dock icon while it runs. A menu bar app is normally
/// an accessory with no Dock presence, but then "is it running?" has no answer
/// short of hunting for the status item - and on a crowded menu bar that item
/// can be hidden entirely. Defaults to showing; the Settings sheet turns it off.
@MainActor
enum DockPresence {
    static let key = "showInDock"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    static func apply(_ enabled: Bool? = nil) {
        if let enabled { UserDefaults.standard.set(enabled, forKey: key) }
        NSApp.setActivationPolicy(isEnabled ? .regular : .accessory)
    }
}

@main
struct ClaudeCronApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = JobStore.shared

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(store)
        } label: {
            MenuBarIcon()
        }
        .menuBarExtraStyle(.window)
    }
}
