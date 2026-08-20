import AppKit
import UserNotifications

@MainActor
enum Notifier {
    static var isBundledApp: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    static func setup(delegate: UNUserNotificationCenterDelegate) {
        guard isBundledApp else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String, jobID: String, runID: String?) {
        guard isBundledApp else {
            postViaOsascript(title: title, body: body)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["jobID": jobID, "runID": runID ?? ""]
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private static func postViaOsascript(title: String, body: String) {
        let clean = { (s: String) in s.replacingOccurrences(of: "\"", with: "'") }
        let script = "display notification \"\(clean(body))\" with title \"\(clean(title))\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }
}
