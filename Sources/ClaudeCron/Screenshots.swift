import AppKit
import SwiftUI

/// Self-portrait mode for the README. `CLAUDE_CRON_SCREENSHOTS=<dir>` makes the
/// app show its panel and Manager as ordinary windows on the primary display,
/// render each window into a bitmap (no screen-recording permission involved),
/// write PNGs into the directory and quit.
///
/// Meant to run against the sandboxed demo config (`make screenshots`), so the
/// pictures show seeded sample jobs and never leak real ones. Driving the real
/// menu bar popover from outside is brittle - it closes on the first focus
/// change - so the panel content is hosted in a plain window styled like it.
@MainActor
enum Screenshots {
    static var outputDir: URL? {
        ProcessInfo.processInfo.environment["CLAUDE_CRON_SCREENSHOTS"].map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        }
    }

    static var isRequested: Bool { outputDir != nil }

    static func runIfRequested() {
        guard let dir = outputDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Let the first layout pass settle before anything is shown.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { shoot(into: dir) }
    }

    private static func shoot(into dir: URL) {
        let store = JobStore.shared
        let state = ManagerState.shared
        guard let screen = NSScreen.screens.first else { finish() ; return }
        let area = screen.visibleFrame

        // --- panel: same view the menu bar extra shows, in a popover-like window
        let panelRoot = PanelView()
            .environmentObject(store)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1))
        let hosting = NSHostingView(rootView: panelRoot)
        var size = hosting.fittingSize
        if size.height < 160 { size.height = 440 }   // ScrollView collapsed: give it room
        size.width = 340
        let panel = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        panel.setFrameTopLeftPoint(NSPoint(x: area.minX + 40, y: area.maxY - 40))
        panel.orderFrontRegardless()

        // --- manager: a Claude job's config tab first
        let configJob = store.jobs.first { $0.id == "daily-standup" }?.id ?? store.jobs.first?.id
        WindowRouter.shared.openManager(select: configJob, tab: .config)
        if let manager = managerWindow() {
            manager.setFrameTopLeftPoint(NSPoint(x: area.minX + 420, y: area.maxY - 40))
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            capture(panel, to: dir.appendingPathComponent("panel.png"))
            if let manager = managerWindow() {
                capture(manager, to: dir.appendingPathComponent("manager-config.png"))
            }

            // --- manager: run history of the job whose last run failed, log selected
            let failedJob = store.jobs.first { spec in
                store.runs(for: spec.id).first?.exitCode.map { $0 != 0 } ?? false
            } ?? store.jobs.first
            if let job = failedJob {
                state.draft = nil
                state.selectedJobID = job.id
                state.tab = .runs
                state.selectedRunID = store.runs(for: job.id).first?.id
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if let manager = managerWindow() {
                    capture(manager, to: dir.appendingPathComponent("manager-runs.png"))
                }
                panel.orderOut(nil)
                finish()
            }
        }
    }

    private static func managerWindow() -> NSWindow? {
        NSApp.windows.first { $0.title == "ClaudeCron Manager" }
    }

    /// Captures the window as the compositor shows it - vibrancy, sidebar
    /// material and all - by asking screencapture for our own window id.
    /// Falls back to rendering the view tree when that yields nothing.
    private static func capture(_ window: NSWindow, to url: URL) {
        window.makeFirstResponder(nil)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        try? task.run()
        task.waitUntilExit()
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > 2_000 {
            print("screenshots: \(url.lastPathComponent) via screencapture (\(size) bytes)")
            return
        }
        renderViewTree(of: window, to: url)
    }

    private static func renderViewTree(of window: NSWindow, to url: URL) {
        guard let frameView = window.contentView?.superview ?? window.contentView else { return }
        let bounds = frameView.bounds
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        frameView.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
        print("screenshots: \(url.lastPathComponent) via view render \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }

    private static func finish() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
    }
}
