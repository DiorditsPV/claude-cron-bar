import AppKit
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // First-launch position for the status item: close to the clock, so it
        // does not land in the notch's blind spot on a crowded menu bar. A user
        // who drags it elsewhere overrides this - registered defaults lose to
        // anything macOS later persists for the item.
        UserDefaults.standard.register(defaults: [
            "NSStatusItem Preferred Position Item-0": 140.0,
        ])
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
