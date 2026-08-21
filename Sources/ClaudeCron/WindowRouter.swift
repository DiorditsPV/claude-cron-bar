import AppKit
import ServiceManagement
import SwiftUI

enum ManagerTab: String {
    case config
    case runs
}

@MainActor
final class ManagerState: ObservableObject {
    static let shared = ManagerState()
    static let allRunsID = "*all-runs*"
    @Published var selectedJobID: String?
    @Published var tab: ManagerTab = .config
    @Published var selectedRunID: String?
    @Published var draft: JobSpec?

    func startDraft() {
        var n = 1
        let existing = Set(JobStore.shared.jobs.map(\.id))
        while existing.contains("job-\(n)") { n += 1 }
        draft = JobSpec(id: "job-\(n)", name: "", workdir: NSHomeDirectory(),
                        schedule: "0 9 * * *", enabled: true)
        selectedJobID = nil
        tab = .config
    }
}

@MainActor
final class WindowRouter: NSObject {
    static let shared = WindowRouter()
    private var window: NSWindow?

    func openManager(select jobID: String? = nil, tab: ManagerTab? = nil,
                     runID: String? = nil) {
        let state = ManagerState.shared
        if let jobID {
            state.draft = nil
            state.selectedJobID = jobID
        }
        if let tab { state.tab = tab }
        state.selectedRunID = runID

        if window == nil {
            let root = ManagerView()
                .environmentObject(JobStore.shared)
                .environmentObject(ManagerState.shared)
            let hosting = NSHostingController(rootView: root)
            hosting.sizingOptions = [.minSize]
            let w = NSWindow(contentViewController: hosting)
            w.title = "ClaudeCron Manager"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 780, height: 560))
            w.isReleasedWhenClosed = false
            w.hidesOnDeactivate = false
            // Ordinary window level: the Manager is a place you go to, not an
            // overlay that sits on top of whatever you are actually doing.
            // The collection behaviour still brings it to the space you are in
            // (including over a full-screen app) instead of switching spaces.
            w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func openNewJob() {
        ManagerState.shared.startDraft()
        openManager()
    }
}

@MainActor
enum LoginItem {
    static var isEnabled: Bool {
        guard Notifier.isBundledApp else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) throws {
        guard Notifier.isBundledApp else { return }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
