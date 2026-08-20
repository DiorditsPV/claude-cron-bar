import Foundation

public enum Paths {
    public static let labelPrefix = "com.local.claudecron."

    public static var configDir: URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CRON_CONFIG"] {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/claude-cron")
    }

    public static var jobsDir: URL { configDir.appendingPathComponent("jobs") }
    public static var binDir: URL { configDir.appendingPathComponent("bin") }
    public static var runnerURL: URL { binDir.appendingPathComponent("runner.zsh") }

    public static var logsRoot: URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CRON_LOGS"] {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/claude-cron")
    }

    /// Pointing this elsewhere puts the app in sandbox mode: plists are written
    /// to the given directory and never handed to launchctl, so a throwaway
    /// instance (tests, demos, screenshots) cannot touch the real user domain.
    public static var launchAgentsOverride: String? {
        ProcessInfo.processInfo.environment["CLAUDE_CRON_LAUNCH_AGENTS"]
    }

    public static var isSandboxed: Bool { launchAgentsOverride != nil }

    public static var launchAgentsDir: URL {
        if let override = launchAgentsOverride {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
    }

    public static func specURL(_ id: String, group: String? = nil) -> URL {
        let dir = group.map { jobsDir.appendingPathComponent($0) } ?? jobsDir
        return dir.appendingPathComponent("\(id).json")
    }

    /// All job spec files: flat in the jobs dir plus one directory level per group.
    public static func specFiles() -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: jobsDir,
                                             includingPropertiesForKeys: nil,
                                             options: [.skipsHiddenFiles]) else { return [] }
        var found: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "json" {
            found.append(url)
        }
        return found
    }

    /// Group = the spec file's parent directory name; nil at the jobs-dir root.
    public static func group(forSpecAt url: URL) -> String? {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        return parent.path == jobsDir.standardizedFileURL.path ? nil : parent.lastPathComponent
    }

    public static func label(_ id: String) -> String { labelPrefix + id }

    public static func plistURL(_ id: String) -> URL {
        launchAgentsDir.appendingPathComponent("\(label(id)).plist")
    }

    public static func jobLogsDir(_ id: String) -> URL {
        logsRoot.appendingPathComponent(id)
    }

    public static func runsURL(_ id: String) -> URL {
        jobLogsDir(id).appendingPathComponent("runs.jsonl")
    }

    public static func runDir(_ id: String, run: String) -> URL {
        jobLogsDir(id).appendingPathComponent(run)
    }

    public static func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [configDir, jobsDir, binDir, logsRoot, launchAgentsDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
