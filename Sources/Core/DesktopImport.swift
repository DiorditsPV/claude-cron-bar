import Foundation

/// A scheduled task discovered in Claude Desktop's local storage.
public struct DesktopTask: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var cron: String
    public var prompt: String
    public var workdir: String?
    public var sourceEnabled: Bool
    public var promptFileMissing: Bool
    public var createdAt: Double

    public init(id: String, name: String, cron: String, prompt: String,
                workdir: String?, sourceEnabled: Bool,
                promptFileMissing: Bool = false, createdAt: Double = 0) {
        self.id = id
        self.name = name
        self.cron = cron
        self.prompt = prompt
        self.workdir = workdir
        self.sourceEnabled = sourceEnabled
        self.promptFileMissing = promptFileMissing
        self.createdAt = createdAt
    }
}

/// Reads Claude Desktop's scheduled-task registries
/// (`claude-code-sessions/**/scheduled-tasks.json`) and resolves each task's
/// prompt from its SKILL.md file.
public enum DesktopImport {
    struct Registry: Decodable {
        let scheduledTasks: [Entry]
    }

    struct Entry: Decodable {
        let id: String
        let cronExpression: String
        let enabled: Bool?
        let filePath: String
        let cwd: String?
        let createdAt: Double?
    }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    }

    public static func registryFiles(under root: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: nil,
                                             options: [.skipsHiddenFiles]) else { return [] }
        var found: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent == "scheduled-tasks.json" {
            found.append(url)
        }
        return found
    }

    public static func findTasks(under root: URL = defaultRoot) -> [DesktopTask] {
        let decoder = JSONDecoder()
        var byID: [String: DesktopTask] = [:]
        for file in registryFiles(under: root) {
            guard let data = try? Data(contentsOf: file),
                  let registry = try? decoder.decode(Registry.self, from: data) else { continue }
            for entry in registry.scheduledTasks {
                let task = resolve(entry)
                if let existing = byID[task.id], existing.createdAt >= task.createdAt {
                    continue
                }
                byID[task.id] = task
            }
        }
        return byID.values.sorted { $0.id < $1.id }
    }

    static func resolve(_ entry: Entry) -> DesktopTask {
        let raw = try? String(contentsOfFile: entry.filePath, encoding: .utf8)
        let parsed = raw.map(parseSkillMarkdown)
        let fallbackName = entry.id
        return DesktopTask(
            id: JobSpec.isValidSlug(entry.id) ? entry.id : JobSpec.slugify(entry.id),
            name: parsed?.name ?? fallbackName,
            cron: entry.cronExpression,
            prompt: parsed?.body ?? "",
            workdir: entry.cwd,
            sourceEnabled: entry.enabled ?? true,
            promptFileMissing: raw == nil,
            createdAt: entry.createdAt ?? 0
        )
    }

    /// Splits an optional YAML frontmatter block off a SKILL.md file and pulls
    /// the `name:` value out of it. The remainder is the prompt body.
    public static func parseSkillMarkdown(_ text: String) -> (name: String?, body: String) {
        let marker = "---"
        var lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == marker else {
            return (nil, text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let close = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == marker
        }) else {
            return (nil, text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let front = lines[1..<close]
        var name: String?
        for line in front {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("name:") {
                name = String(trimmed.dropFirst("name:".count))
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        lines.removeSubrange(0...close)
        let body = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (name?.isEmpty == true ? nil : name, body)
    }
}
