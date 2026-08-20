import Foundation

public struct CommandResult {
    public let status: Int32
    public let output: String
}

public enum LaunchdError: Error, LocalizedError {
    case commandFailed(String, Int32, String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let cmd, let status, let output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return "launchctl \(cmd) failed (\(status))\(detail.isEmpty ? "" : ": \(detail)")"
        }
    }
}

public struct LaunchdManager {
    let uid = getuid()

    public init() {}

    var domain: String { "gui/\(uid)" }

    @discardableResult
    func launchctl(_ args: [String]) -> CommandResult {
        if Paths.isSandboxed {
            return CommandResult(status: 0, output: "sandboxed: launchctl \(args.joined(separator: " "))")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, output: "\(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus,
                             output: String(data: data, encoding: .utf8) ?? "")
    }

    public func writePlist(for spec: JobSpec) throws {
        let intervals = try CronSchedule.parse(spec.schedule).launchdCalendarIntervals()
        let logsDir = Paths.jobLogsDir(spec.id)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": Paths.label(spec.id),
            "ProgramArguments": ["/bin/zsh", "-l", "-c", "exec \"$0\" \"$1\"",
                                 Paths.runnerURL.path, spec.id],
            "StartCalendarInterval": intervals,
            "StandardOutPath": logsDir.appendingPathComponent("launchd.out").path,
            "StandardErrorPath": logsDir.appendingPathComponent("launchd.err").path,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                     format: .xml, options: 0)
        try data.write(to: Paths.plistURL(spec.id), options: .atomic)
    }

    public func removePlist(id: String) {
        try? FileManager.default.removeItem(at: Paths.plistURL(id))
    }

    public func isLoaded(id: String) -> Bool {
        // Nothing is ever registered with launchd in sandbox mode, so runs
        // started from the UI are spawned by the app itself.
        guard !Paths.isSandboxed else { return false }
        return launchctl(["print", "\(domain)/\(Paths.label(id))"]).status == 0
    }

    public func bootstrap(id: String) throws {
        let result = launchctl(["bootstrap", domain, Paths.plistURL(id).path])
        guard result.status == 0 else {
            throw LaunchdError.commandFailed("bootstrap", result.status, result.output)
        }
    }

    public func bootout(id: String) {
        launchctl(["bootout", "\(domain)/\(Paths.label(id))"])
    }

    public func kickstart(id: String) throws {
        let result = launchctl(["kickstart", "\(domain)/\(Paths.label(id))"])
        guard result.status == 0 else {
            throw LaunchdError.commandFailed("kickstart", result.status, result.output)
        }
    }

    public func terminate(id: String) {
        launchctl(["kill", "TERM", "\(domain)/\(Paths.label(id))"])
    }
}
