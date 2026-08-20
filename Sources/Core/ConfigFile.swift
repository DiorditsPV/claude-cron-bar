import Foundation

public struct TelegramConfig: Codable, Equatable, Sendable {
    public var botToken: String
    public var chatID: String
    public var apiBase: String?
    public var proxy: String?

    public init(botToken: String = "", chatID: String = "", apiBase: String? = nil,
                proxy: String? = nil) {
        self.botToken = botToken
        self.chatID = chatID
        self.apiBase = apiBase
        self.proxy = proxy
    }

    public var isConfigured: Bool { !botToken.isEmpty && !chatID.isEmpty }

    public var resolvedAPIBase: String {
        let base = apiBase?.trimmingCharacters(in: .whitespaces) ?? ""
        return base.isEmpty ? "https://api.telegram.org" : base
    }
}

public struct AppConfig: Codable, Equatable, Sendable {
    public var telegram: TelegramConfig?

    public init(telegram: TelegramConfig? = nil) {
        self.telegram = telegram
    }
}

public enum ConfigFile {
    public static var url: URL { Paths.configDir.appendingPathComponent("config.json") }

    public static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return AppConfig()
        }
        return config
    }

    // The bot token lands on disk, so the file is kept user-readable only.
    public static func save(_ config: AppConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try FileManager.default.createDirectory(at: Paths.configDir,
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: url.path)
    }
}
