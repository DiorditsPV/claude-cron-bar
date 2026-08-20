import AppKit
import SwiftUI

struct ManagerView: View {
    @EnvironmentObject var store: JobStore
    @EnvironmentObject var state: ManagerState
    @State private var showImport = false
    @State private var showSettings = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $state.selectedJobID) {
                    Section {
                        Label("All Runs", systemImage: "clock.arrow.circlepath")
                            .tag(ManagerState.allRunsID)
                    }
                    ForEach(store.groupedJobs, id: \.group) { entry in
                        Section {
                            ForEach(entry.jobs) { spec in
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(jobStatus(spec, store: store).color)
                                        .frame(width: 8, height: 8)
                                    Text(spec.name.isEmpty ? spec.id : spec.name)
                                        .lineLimit(1)
                                    Spacer()
                                    if let accent = paletteColor(spec.color) {
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(accent)
                                            .frame(width: 7, height: 7)
                                    }
                                }
                                .tag(spec.id)
                            }
                        } header: {
                            if let group = entry.group { Text(group) }
                        }
                    }
                }
                Divider()
                HStack {
                    Button {
                        state.startDraft()
                    } label: {
                        Label("New Job", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    Button {
                        NSWorkspace.shared.open(Paths.jobsDir)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Open the jobs folder in Finder")
                    Button {
                        JobsFolder.openClaudeSession()
                    } label: {
                        Image(systemName: "apple.terminal")
                    }
                    .buttonStyle(.borderless)
                    .help("Open a Claude session in Terminal at the jobs folder")
                    Button {
                        showImport = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderless)
                    .help("Import scheduled tasks from Claude Desktop")
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.borderless)
                    .help("Settings (Telegram)")
                }
                .padding(8)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200)
        } detail: {
            if let draft = state.draft {
                JobDetailView(spec: draft, isNew: true)
                    .id("draft-\(draft.id)")
            } else if state.selectedJobID == ManagerState.allRunsID {
                AllRunsView()
            } else if let id = state.selectedJobID,
                      let spec = store.jobs.first(where: { $0.id == id }) {
                JobDetailView(spec: spec, isNew: false)
                    .id(spec.id)
            } else {
                Text("Select a job or create a new one")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: state.selectedJobID) { _, newValue in
            if newValue != nil { state.draft = nil }
        }
        .sheet(isPresented: $showImport) {
            ImportSheet()
                .environmentObject(store)
                .environmentObject(state)
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
        }
        .alert("Error", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )) {
            Button("OK") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

struct JobDetailView: View {
    @EnvironmentObject var store: JobStore
    @EnvironmentObject var state: ManagerState
    let spec: JobSpec
    let isNew: Bool

    var body: some View {
        VStack(spacing: 0) {
            if isNew {
                ConfigForm(original: spec, isNew: true)
            } else {
                Picker("", selection: $state.tab) {
                    Text("Config").tag(ManagerTab.config)
                    Text("Runs").tag(ManagerTab.runs)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .padding(.top, 10)

                switch state.tab {
                case .config:
                    ConfigForm(original: spec, isNew: false)
                case .runs:
                    RunsView(spec: spec)
                }
            }
        }
    }
}

struct ConfigForm: View {
    @EnvironmentObject var store: JobStore
    @EnvironmentObject var state: ManagerState

    let original: JobSpec
    let isNew: Bool

    @State private var form: JobSpec
    @State private var idEdited: Bool
    @State private var showDeleteDialog = false
    @State private var modelChoice: String
    @State private var customModel: String
    @State private var telegramConfigured: Bool

    private static let modelPresets = ["opus", "sonnet", "haiku"]
    private static let effortLevels = ["low", "medium", "high", "xhigh", "max"]

    init(original: JobSpec, isNew: Bool) {
        self.original = original
        self.isNew = isNew
        _form = State(initialValue: original)
        _idEdited = State(initialValue: !isNew)
        _telegramConfigured = State(initialValue:
            ConfigFile.load().telegram?.isConfigured ?? false)
        let model = original.model ?? ""
        if model.isEmpty {
            _modelChoice = State(initialValue: "default")
            _customModel = State(initialValue: "")
        } else if Self.modelPresets.contains(model) {
            _modelChoice = State(initialValue: model)
            _customModel = State(initialValue: "")
        } else {
            _modelChoice = State(initialValue: "custom")
            _customModel = State(initialValue: model)
        }
    }

    private var validationError: String? {
        if form.name.trimmingCharacters(in: .whitespaces).isEmpty { return "Name is required" }
        if !JobSpec.isValidSlug(form.id) {
            return "ID must be lowercase letters, digits and hyphens"
        }
        if isNew && store.jobs.contains(where: { $0.id == form.id }) {
            return "ID \"\(form.id)\" is already in use"
        }
        if let group = form.group, !JobSpec.isValidGroup(group) {
            return "Group must be letters, digits, hyphens or underscores"
        }
        var isDir: ObjCBool = false
        let path = (form.workdir as NSString).expandingTildeInPath
        if !FileManager.default.fileExists(atPath: path, isDirectory: &isDir) || !isDir.boolValue {
            return "Working directory does not exist"
        }
        switch form.kind {
        case .claude:
            if form.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Prompt is empty"
            }
        case .shell:
            if form.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Command is empty"
            }
        }
        if case .failure(let error) = cronResult {
            return error.localizedDescription
        }
        return nil
    }

    private var cronResult: Result<[Date], Error> {
        do {
            let schedule = try CronSchedule.parse(form.schedule)
            _ = try schedule.launchdCalendarIntervals()
            return .success(schedule.nextDates(after: Date(), count: 3))
        } catch {
            return .failure(error)
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $form.name)
                    .onChange(of: form.name) { _, newValue in
                        if isNew && !idEdited {
                            form.id = JobSpec.slugify(newValue)
                        }
                    }
                TextField("ID", text: $form.id)
                    .disabled(!isNew)
                    .foregroundStyle(isNew ? .primary : .secondary)
                    .onChange(of: form.id) { _, _ in
                        if isNew && form.id != JobSpec.slugify(form.name) { idEdited = true }
                    }
                Picker("Type", selection: $form.kind) {
                    Text("Claude prompt").tag(JobKind.claude)
                    Text("Shell command").tag(JobKind.shell)
                }
                .pickerStyle(.segmented)
                HStack {
                    TextField("Group", text: Binding(
                        get: { form.group ?? "" },
                        set: {
                            let trimmed = $0.trimmingCharacters(in: .whitespaces)
                            form.group = trimmed.isEmpty ? nil : trimmed
                        }
                    ), prompt: Text("none"))
                    if !store.existingGroups.isEmpty {
                        Menu {
                            Button("None") { form.group = nil }
                            ForEach(store.existingGroups, id: \.self) { group in
                                Button(group) { form.group = group }
                            }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
                LabeledContent("Color") {
                    HStack(spacing: 7) {
                        colorSwatch(nil)
                        ForEach(JobSpec.palette, id: \.self) { colorSwatch($0) }
                    }
                }
            }

            Section {
                if form.kind == .claude {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Prompt").font(.caption).foregroundStyle(.secondary)
                        ResizableTextEditor(text: $form.prompt,
                                            storageKey: "editorHeight.prompt",
                                            defaultHeight: 160)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Command").font(.caption).foregroundStyle(.secondary)
                        ResizableTextEditor(text: $form.command,
                                            font: .body.monospaced(),
                                            storageKey: "editorHeight.command",
                                            defaultHeight: 100)
                    }
                }

                HStack {
                    TextField("Working directory", text: $form.workdir)
                    Button {
                        pickDirectory()
                    } label: {
                        Image(systemName: "folder")
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    TextField("Schedule (cron)", text: $form.schedule)
                        .font(.body.monospaced())
                    switch cronResult {
                    case .success(let dates):
                        Text("next: " + dates.map { Fmt.abs($0) }.joined(separator: ",  "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .failure(let error):
                        Text(error.localizedDescription)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            if form.kind == .claude {
                Section {
                    Picker("Model", selection: $modelChoice) {
                        Text("default").tag("default")
                        ForEach(Self.modelPresets, id: \.self) { Text($0).tag($0) }
                        Text("custom\u{2026}").tag("custom")
                    }
                    if modelChoice == "custom" {
                        TextField("Model ID", text: $customModel,
                                  prompt: Text("e.g. claude-opus-5"))
                            .font(.body.monospaced())
                    }
                    Picker("Effort", selection: Binding(
                        get: { form.effort ?? "default" },
                        set: { form.effort = $0 == "default" ? nil : $0 }
                    )) {
                        Text("default").tag("default")
                        ForEach(Self.effortLevels, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Extra CLI args", text: $form.extraArgs)
                        .font(.body.monospaced())
                    Toggle("Skip permission prompts (--dangerously-skip-permissions)",
                           isOn: $form.skipPermissions)
                }
            }

            Section {
                Toggle("Notify on success", isOn: $form.notifyOnSuccess)
                Toggle("Send result to Telegram", isOn: $form.telegramNotify)
                if form.telegramNotify && !telegramConfigured {
                    Text("Telegram is not configured yet - set the bot token and chat ID via the gear button")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if form.telegramNotify {
                    Text("Default: status + the job's stdout. For a richer delivery, have the job save files into $CLAUDE_CRON_OUTBOX - .md/.txt go out as messages, other files as attachments.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Enabled (scheduled)", isOn: $form.enabled)
            }

            Section {
                HStack {
                    Button(isNew ? "Create" : "Save") { save() }
                        .keyboardShortcut("s", modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(validationError != nil)
                    if !isNew {
                        Button("Run Now") { store.runNow(original) }
                    }
                    if let error = validationError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    Spacer()
                    if !isNew {
                        Button("Delete", role: .destructive) { showDeleteDialog = true }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete \"\(original.name)\"?",
                            isPresented: $showDeleteDialog) {
            Button("Delete, keep logs", role: .destructive) {
                store.delete(original, deleteLogs: false)
                state.selectedJobID = nil
            }
            Button("Delete with logs", role: .destructive) {
                store.delete(original, deleteLogs: true)
                state.selectedJobID = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The launchd agent is removed. Run history can be kept or deleted.")
        }
    }

    private func save() {
        var spec = form
        spec.workdir = (spec.workdir as NSString).expandingTildeInPath
        switch modelChoice {
        case "default":
            spec.model = nil
        case "custom":
            let trimmed = customModel.trimmingCharacters(in: .whitespaces)
            spec.model = trimmed.isEmpty ? nil : trimmed
        default:
            spec.model = modelChoice
        }
        do {
            try store.save(spec)
            if isNew {
                state.draft = nil
                state.selectedJobID = spec.id
            }
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    @ViewBuilder
    private func colorSwatch(_ name: String?) -> some View {
        let selected = form.color == name
        ZStack {
            Circle()
                .fill(paletteColor(name) ?? Color.secondary.opacity(0.15))
            if name == nil {
                Image(systemName: "slash.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 20, height: 20)
        .overlay(Circle().stroke(selected ? Color.accentColor : Color.secondary.opacity(0.3),
                                 lineWidth: selected ? 2.5 : 1))
        .contentShape(Circle().inset(by: -4))
        .onTapGesture { form.color = name }
        .help(name ?? "no color")
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: (form.workdir as NSString).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url {
            form.workdir = url.path
        }
    }
}

@MainActor
enum JobsFolder {
    static func openClaudeSession() {
        let shellPath = Paths.jobsDir.path.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        tell application "Terminal"
            activate
            do script "cd '\(shellPath)' && claude"
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }
}
