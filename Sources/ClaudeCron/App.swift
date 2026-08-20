import AppKit
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Notifier.setup(delegate: self)
        if !UserDefaults.standard.bool(forKey: "didOfferLoginItem") {
            UserDefaults.standard.set(true, forKey: "didOfferLoginItem")
            try? LoginItem.set(true)
        }
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
