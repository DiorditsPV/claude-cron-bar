import AppKit
import SwiftUI

struct RunsView: View {
    @EnvironmentObject var store: JobStore
    @EnvironmentObject var state: ManagerState
    let spec: JobSpec

    @State private var showClearDialog = false

    var body: some View {
        let runs = store.runs(for: spec.id)
        VSplitView {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Clear History") { showClearDialog = true }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .disabled(runs.filter { $0.state != .running }.isEmpty)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 2)
                List(runs, selection: $state.selectedRunID) { run in
                    RunRow(run: run, onDelete: run.state == .running ? nil : {
                        store.deleteRun(run)
                        if state.selectedRunID == run.id { state.selectedRunID = nil }
                    })
                        .tag(run.id)
                        .contextMenu {
                            if run.state == .running {
                                Button("Stop") { store.stop(spec) }
                            } else {
                                Button("Delete Run", role: .destructive) {
                                    store.deleteRun(run)
                                    if state.selectedRunID == run.id {
                                        state.selectedRunID = nil
                                    }
                                }
                            }
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting(
                                    [Paths.runDir(spec.id, run: run.id)])
                            }
                        }
                }
            }
            .frame(minHeight: 140)
            .confirmationDialog("Delete all finished runs of \"\(spec.name)\"?",
                                isPresented: $showClearDialog) {
                Button("Delete All", role: .destructive) {
                    store.clearRuns(for: spec)
                    state.selectedRunID = nil
                }
                Button("Cancel", role: .cancel) {}
            }
            .onAppear {
                store.beginPanelRefresh()
                if state.selectedRunID == nil { state.selectedRunID = runs.first?.id }
            }
            .onDisappear { store.endPanelRefresh() }

            if let runID = state.selectedRunID,
               let run = runs.first(where: { $0.id == runID }) {
                LogPane(spec: spec, run: run)
                    .frame(minHeight: 160)
            } else {
                Text(runs.isEmpty ? "No runs yet" : "Select a run to view its log")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.top, 8)
    }
}

struct RunRow: View {
    let run: Run
    var jobName: String?
    var onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            switch run.state {
            case .running:
                ProgressView().controlSize(.small)
            case .success:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failure:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case .interrupted:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            }
            if let jobName {
                Text(jobName)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            Text(Fmt.abs(run.start))
            if let duration = run.duration {
                Text(Fmt.duration(duration)).foregroundStyle(.secondary)
            }
            Spacer()
            if let exit = run.exitCode, exit != 0 {
                Text("exit \(exit)").font(.caption).foregroundStyle(.red)
            } else if run.state == .interrupted {
                Text("interrupted").font(.caption).foregroundStyle(.orange)
            }
            if let onDelete {
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Delete run")
            }
        }
    }
}

struct AllRunsView: View {
    @EnvironmentObject var store: JobStore
    @EnvironmentObject var state: ManagerState

    private var allRuns: [(run: Run, spec: JobSpec)] {
        store.jobs
            .flatMap { spec in store.runs(for: spec.id).map { (run: $0, spec: spec) } }
            .sorted { $0.run.start > $1.run.start }
    }

    var body: some View {
        let items = allRuns
        VSplitView {
            List(selection: $state.selectedRunID) {
                ForEach(items, id: \.run.id) { item in
                    RunRow(run: item.run,
                           jobName: item.spec.name.isEmpty ? item.spec.id : item.spec.name,
                           onDelete: item.run.state == .running ? nil : {
                               store.deleteRun(item.run)
                               if state.selectedRunID == item.run.id {
                                   state.selectedRunID = nil
                               }
                           })
                        .tag(item.run.id)
                        .contextMenu {
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting(
                                    [Paths.runDir(item.spec.id, run: item.run.id)])
                            }
                        }
                }
            }
            .frame(minHeight: 140)
            .onAppear { store.beginPanelRefresh() }
            .onDisappear { store.endPanelRefresh() }

            if let runID = state.selectedRunID,
               let item = items.first(where: { $0.run.id == runID }) {
                LogPane(spec: item.spec, run: item.run)
                    .frame(minHeight: 160)
            } else {
                Text(items.isEmpty ? "No runs yet" : "Select a run to view its log")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.top, 8)
    }
}

struct LogPane: View {
    let spec: JobSpec
    let run: Run

    @State private var showing: Output = .log
    @State private var content = ""

    enum Output: String, CaseIterable {
        case log = "Log"
        case result = "Result"
    }

    private var fileURL: URL {
        let dir = Paths.runDir(spec.id, run: run.id)
        return dir.appendingPathComponent(showing == .log ? "run.log" : "result.md")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $showing) {
                    ForEach(Output.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
                Spacer()
                Button("Open in Editor") {
                    NSWorkspace.shared.open(fileURL)
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                } label: {
                    Image(systemName: "folder")
                }
                .help("Reveal in Finder")
            }
            .buttonStyle(.borderless)
            .padding(8)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    Text(content.isEmpty ? "(empty)" : content)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: content) { _, _ in
                    if run.state == .running { proxy.scrollTo("bottom") }
                }
            }
        }
        .onAppear { reload() }
        .onChange(of: showing) { _, _ in reload() }
        .onChange(of: run.id) { _, _ in reload() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if run.state == .running { reload() }
        }
    }

    private func reload() {
        content = Self.tail(fileURL)
    }

    static func tail(_ url: URL, maxBytes: UInt64 = 65536) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > maxBytes ? size - maxBytes : 0
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        var text = String(decoding: data, as: UTF8.self)
        if offset > 0, let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
        }
        return text
    }
}
