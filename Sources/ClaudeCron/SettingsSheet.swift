import SwiftUI

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var botToken = ""
    @State private var chatID = ""
    @State private var apiBase = ""
    @State private var proxy = ""
    @State private var status = ""
    @State private var busy = false
    @State private var showInDock = DockPresence.isEnabled

    var body: some View {
        VStack(spacing: 0) {
            Text("Settings").font(.headline).padding(12)
            Divider()

            Form {
                Section {
                    Toggle("Show in Dock", isOn: $showInDock)
                        .onChange(of: showInDock) { _, value in DockPresence.apply(value) }
                } header: {
                    Text("General")
                } footer: {
                    Text("A Dock icon answers \"is it running?\" and gives the app somewhere to be clicked. Turn it off to live in the menu bar alone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextField("Bot token", text: $botToken,
                              prompt: Text("123456:ABC-DEF\u{2026} (from @BotFather)"))
                        .font(.body.monospaced())
                    HStack {
                        TextField("Chat ID", text: $chatID, prompt: Text("e.g. 123456789"))
                            .font(.body.monospaced())
                        Button("Detect") { detectChat() }
                            .disabled(botToken.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                            .help("Send any message to your bot in Telegram, then click here")
                    }
                    TextField("API base", text: $apiBase,
                              prompt: Text("https://api.telegram.org"))
                        .font(.body.monospaced())
                    HStack {
                        TextField("Proxy", text: $proxy,
                                  prompt: Text("http://proxy-host:3128"))
                            .font(.body.monospaced())
                        Button("From env") { prefillProxyFromEnvironment(force: true) }
                            .disabled(busy)
                            .help("Read HTTPS_PROXY from your login shell")
                    }
                    HStack(spacing: 8) {
                        Button("Send Test") { sendTest() }
                            .disabled(!currentConfig.isConfigured || busy)
                        if busy { ProgressView().controlSize(.small) }
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                } header: {
                    Text("Telegram")
                } footer: {
                    Text("Jobs with \"Send result to Telegram\" enabled post their result (or the failure log tail) to this chat after every run. The runner sends it, so the app does not need to be open.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(width: 500, height: 460)
        .onAppear {
            let tg = ConfigFile.load().telegram ?? TelegramConfig()
            botToken = tg.botToken
            chatID = tg.chatID
            apiBase = tg.apiBase ?? ""
            proxy = tg.proxy ?? ""
            if proxy.isEmpty { prefillProxyFromEnvironment(force: false) }
        }
    }

    private var currentConfig: TelegramConfig {
        let base = apiBase.trimmingCharacters(in: .whitespaces)
        let proxyValue = proxy.trimmingCharacters(in: .whitespaces)
        return TelegramConfig(botToken: botToken.trimmingCharacters(in: .whitespaces),
                              chatID: chatID.trimmingCharacters(in: .whitespaces),
                              apiBase: base.isEmpty ? nil : base,
                              proxy: proxyValue.isEmpty ? nil : proxyValue)
    }

    /// Reads HTTPS_PROXY from a login shell - the app itself is launched by
    /// LaunchServices and does not inherit shell environment.
    private func prefillProxyFromEnvironment(force: Bool) {
        Task {
            let value = await Self.shellHTTPSProxy()
            if let value, !value.isEmpty, force || proxy.isEmpty {
                proxy = value
                status = "Proxy taken from HTTPS_PROXY"
            } else if force {
                status = "HTTPS_PROXY is not set in the login shell"
            }
        }
    }

    private static func shellHTTPSProxy() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-l", "-c",
                                     "print -rn -- ${HTTPS_PROXY:-${https_proxy:-}}"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let value = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: value)
            }
        }
    }

    private func save() {
        var config = ConfigFile.load()
        config.telegram = currentConfig
        do {
            try ConfigFile.save(config)
            dismiss()
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
    }

    private func makeSession() -> URLSession {
        guard var proxyString = currentConfig.proxy, !proxyString.isEmpty else {
            return URLSession.shared
        }
        if !proxyString.contains("://") { proxyString = "http://" + proxyString }
        guard let proxyURL = URL(string: proxyString), let host = proxyURL.host else {
            return URLSession.shared
        }
        let port = proxyURL.port ?? 3128
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: true,
            kCFNetworkProxiesHTTPProxy as String: host,
            kCFNetworkProxiesHTTPPort as String: port,
            kCFNetworkProxiesHTTPSEnable as String: true,
            kCFNetworkProxiesHTTPSProxy as String: host,
            kCFNetworkProxiesHTTPSPort as String: port,
        ]
        let delegate = ProxyAuthDelegate(username: proxyURL.user(percentEncoded: false),
                                         password: proxyURL.password(percentEncoded: false))
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    private func request(_ method: String,
                         body: [String: Any]? = nil) async throws -> [String: Any] {
        let tg = currentConfig
        guard let url = URL(string: "\(tg.resolvedAPIBase)/bot\(tg.botToken)/\(method)") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let session = makeSession()
        defer { if session !== URLSession.shared { session.finishTasksAndInvalidate() } }
        let (data, _) = try await session.data(for: req)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func detectChat() {
        busy = true
        status = ""
        Task {
            defer { busy = false }
            do {
                let json = try await request("getUpdates")
                guard json["ok"] as? Bool == true,
                      let updates = json["result"] as? [[String: Any]] else {
                    status = "Telegram error: \(json["description"] as? String ?? "unexpected response")"
                    return
                }
                let chats: [(String, String)] = updates.compactMap { update in
                    guard let message = (update["message"] ?? update["channel_post"])
                            as? [String: Any],
                          let chat = message["chat"] as? [String: Any],
                          let id = (chat["id"] as? NSNumber)?.stringValue else { return nil }
                    let title = (chat["title"] ?? chat["username"] ?? chat["first_name"])
                        as? String ?? id
                    return (id, title)
                }
                if let latest = chats.last {
                    chatID = latest.0
                    status = "Found chat: \(latest.1)"
                } else {
                    status = "No messages yet - write something to the bot first"
                }
            } catch {
                status = "Request failed: \(error.localizedDescription)"
            }
        }
    }

    private func sendTest() {
        busy = true
        status = ""
        Task {
            defer { busy = false }
            do {
                let json = try await request("sendMessage", body: [
                    "chat_id": currentConfig.chatID,
                    "text": "ClaudeCron test message \u{2705}",
                ])
                status = json["ok"] as? Bool == true
                    ? "Test message sent"
                    : "Telegram error: \(json["description"] as? String ?? "unexpected response")"
            } catch {
                status = "Request failed: \(error.localizedDescription)"
            }
        }
    }
}

final class ProxyAuthDelegate: NSObject, URLSessionTaskDelegate {
    private let username: String?
    private let password: String?

    init(username: String?, password: String?) {
        self.username = username
        self.password = password
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition,
                                                  URLCredential?) -> Void) {
        if challenge.protectionSpace.isProxy(), let username, let password {
            completionHandler(.useCredential,
                              URLCredential(user: username, password: password,
                                            persistence: .forSession))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
