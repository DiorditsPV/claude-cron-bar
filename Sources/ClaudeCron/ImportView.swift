import SwiftUI

struct ImportSheet: View {
    @EnvironmentObject var store: JobStore
    @EnvironmentObject var state: ManagerState
    @Environment(\.dismiss) private var dismiss

    @State private var tasks: [DesktopTask] = []
    @State private var selected: Set<String> = []
    @State private var scanned = false

    private func exists(_ task: DesktopTask) -> Bool {
        store.jobs.contains { $0.id == task.id }
    }

    private func cronProblem(_ task: DesktopTask) -> String? {
        do {
            _ = try CronSchedule.parse(task.cron).launchdCalendarIntervals()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func importable(_ task: DesktopTask) -> Bool {
        !exists(task) && cronProblem(task) == nil && !task.promptFileMissing
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Import from Claude Desktop")
                .font(.headline)
                .padding(12)

            Divider()

            if !scanned {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tasks.isEmpty {
                Text("No scheduled tasks found in Claude Desktop storage")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(tasks) { task in
                        TaskRow(task: task,
                                exists: exists(task),
                                cronProblem: cronProblem(task),
                                isOn: Binding(
                                    get: { selected.contains(task.id) },
                                    set: { on in
                                        if on { selected.insert(task.id) }
                                        else { selected.remove(task.id) }
                                    }
                                ),
                                importable: importable(task))
                    }
                }
            }

            Divider()

            Text("Imported jobs are created paused. Pause or delete the routine in Claude Desktop before enabling them here, or both will run.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 8)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Import \(selected.count) job\(selected.count == 1 ? "" : "s")") {
                    runImport()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 560, height: 420)
        .onAppear { scan() }
    }

    private func scan() {
        tasks = DesktopImport.findTasks()
        selected = Set(tasks.filter { importable($0) }.map(\.id))
        scanned = true
    }

    private func runImport() {
        var firstID: String?
        for task in tasks where selected.contains(task.id) && importable(task) {
            let spec = JobSpec(id: task.id,
                               name: task.name,
                               kind: .claude,
                               prompt: task.prompt,
                               workdir: task.workdir ?? NSHomeDirectory(),
                               schedule: task.cron,
                               enabled: false)
            do {
                try store.save(spec)
                if firstID == nil { firstID = spec.id }
            } catch {
                store.lastError = "Import of \"\(task.id)\" failed: \(error.localizedDescription)"
            }
        }
        if let firstID {
            state.selectedJobID = firstID
            state.tab = .config
        }
        dismiss()
    }
}

private struct TaskRow: View {
    let task: DesktopTask
    let exists: Bool
    let cronProblem: String?
    @Binding var isOn: Bool
    let importable: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .disabled(!importable)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(task.name).fontWeight(.medium)
                    if !task.sourceEnabled {
                        Badge(text: "paused in Desktop", color: .secondary)
                    }
                    if exists {
                        Badge(text: "already imported", color: .secondary)
                    }
                    if task.promptFileMissing {
                        Badge(text: "prompt file missing", color: .orange)
                    }
                    if let problem = cronProblem {
                        Badge(text: problem, color: .red)
                    }
                }
                Text(task.cron)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if let dir = task.workdir {
                    Text(dir)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(importable || isOn ? 1 : 0.6)
    }
}

private struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
