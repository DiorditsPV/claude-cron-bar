import Foundation

public enum JobKind: String, Codable, CaseIterable, Sendable {
    case claude
    case shell
}

public struct JobSpec: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var kind: JobKind
    public var prompt: String
    public var command: String
    public var workdir: String
    public var schedule: String
    public var model: String?
    public var effort: String?
    public var extraArgs: String
    public var group: String?
    public var color: String?
    public var skipPermissions: Bool
    /// Delivery: which channel carries what. A channel that can only report the
    /// fact of a run (the macOS notification) has one switch; Telegram can also
    /// carry the job's output, so it has two. A failure is reported regardless -
    /// a scheduled job failing in silence is worse than one extra message.
    public var notifyOnSuccess: Bool
    public var telegramStatus: Bool
    public var telegramOutput: Bool
    public var enabled: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String,
                name: String,
                kind: JobKind = .claude,
                prompt: String = "",
                command: String = "",
                workdir: String,
                schedule: String,
                model: String? = nil,
                effort: String? = nil,
                extraArgs: String = "",
                group: String? = nil,
                color: String? = nil,
                skipPermissions: Bool = true,
                notifyOnSuccess: Bool = false,
                telegramStatus: Bool = false,
                telegramOutput: Bool = false,
                enabled: Bool = true,
                createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.kind = kind
        self.prompt = prompt
        self.command = command
        self.workdir = workdir
        self.schedule = schedule
        self.model = model
        self.effort = effort
        self.extraArgs = extraArgs
        self.group = group
        self.color = color
        self.skipPermissions = skipPermissions
        self.notifyOnSuccess = notifyOnSuccess
        self.telegramStatus = telegramStatus
        self.telegramOutput = telegramOutput
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // Tolerant decoding so hand-edited spec files with omitted fields stay valid.
    /// Key of the pre-split delivery flag, kept for reading old specs only.
    private enum LegacyKeys: String, CodingKey { case telegramNotify }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        kind = try c.decodeIfPresent(JobKind.self, forKey: .kind) ?? .claude
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        workdir = try c.decodeIfPresent(String.self, forKey: .workdir) ?? NSHomeDirectory()
        schedule = try c.decode(String.self, forKey: .schedule)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
        extraArgs = try c.decodeIfPresent(String.self, forKey: .extraArgs) ?? ""
        group = try c.decodeIfPresent(String.self, forKey: .group)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        skipPermissions = try c.decodeIfPresent(Bool.self, forKey: .skipPermissions) ?? true
        notifyOnSuccess = try c.decodeIfPresent(Bool.self, forKey: .notifyOnSuccess) ?? false
        // telegramNotify predates the split and meant "status and output".
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let legacyTelegram = try legacy.decodeIfPresent(Bool.self, forKey: .telegramNotify) ?? false
        telegramStatus = try c.decodeIfPresent(Bool.self, forKey: .telegramStatus) ?? legacyTelegram
        telegramOutput = try c.decodeIfPresent(Bool.self, forKey: .telegramOutput) ?? legacyTelegram
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    public static func slugify(_ name: String) -> String {
        let lowered = name.lowercased()
        var out = ""
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                out.append(ch.isASCII ? ch : "-")
            } else {
                out.append("-")
            }
        }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(out.prefix(40))
    }

    public static func isValidSlug(_ slug: String) -> Bool {
        guard !slug.isEmpty, slug.count <= 40 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        guard slug.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        return !slug.hasPrefix("-") && !slug.hasSuffix("-")
    }

    /// Group names become directory names under the jobs dir.
    public static func isValidGroup(_ group: String) -> Bool {
        guard !group.isEmpty, group.count <= 40 else { return false }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_")
        guard group.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        return true
    }

    /// The six-color palette; `color` holds one of these names or nil.
    public static let palette = ["red", "orange", "yellow", "green", "blue", "purple"]
}

public enum RunState: String, Sendable {
    case running
    case success
    case failure
    case interrupted
}

public struct Run: Identifiable, Equatable, Sendable {
    public var id: String
    public var job: String
    public var start: Date
    public var end: Date?
    public var exitCode: Int?
    public var pid: Int?

    public init(id: String, job: String, start: Date, end: Date? = nil,
                exitCode: Int? = nil, pid: Int? = nil) {
        self.id = id
        self.job = job
        self.start = start
        self.end = end
        self.exitCode = exitCode
        self.pid = pid
    }

    public var state: RunState {
        if let exit = exitCode { return exit == 0 ? .success : .failure }
        if end != nil { return .failure }
        if let pid, kill(pid_t(pid), 0) == 0 { return .running }
        return .interrupted
    }

    public var duration: TimeInterval? {
        guard let end else {
            return state == .running ? Date().timeIntervalSince(start) : nil
        }
        return end.timeIntervalSince(start)
    }
}
