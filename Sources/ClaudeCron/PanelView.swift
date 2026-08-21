import SwiftUI

struct PanelView: View {
    @EnvironmentObject var store: JobStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("ClaudeCron").font(.headline)
                Spacer()
                Text("\(store.jobs.count) job\(store.jobs.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if store.jobs.isEmpty {
                VStack(spacing: 8) {
                    Text("No jobs yet").foregroundStyle(.secondary)
                    Button("+ New Job") { WindowRouter.shared.openNewJob() }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.groupedJobs, id: \.group) { entry in
                            if let group = entry.group {
                                Text(group.uppercased())
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 8)
                                    .padding(.bottom, 2)
                            }
                            ForEach(entry.jobs) { spec in
                                JobRow(spec: spec)
                                if spec.id != entry.jobs.last?.id {
                                    Divider().padding(.leading, 26)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }
                .frame(maxHeight: 430)
            }

            Divider()

            HStack {
                Button("+ New Job") { WindowRouter.shared.openNewJob() }
                Button("Manager") { WindowRouter.shared.openManager() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 340)
        .onAppear {
            store.beginPanelRefresh()
            store.markFailuresSeen()
        }
        .onDisappear { store.endPanelRefresh() }
    }
}

private struct JobRow: View {
    @EnvironmentObject var store: JobStore
    let spec: JobSpec
    @State private var hovering = false

    var body: some View {
        let status = jobStatus(spec, store: store)
        let running = status == .running

        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(status.color)
                .frame(width: 9, height: 9)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(spec.name.isEmpty ? spec.id : spec.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if let summary = lastRunSummary(spec, store: store) {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(status == .failed ? .red : .secondary)
                }
                if let next = store.nextRun(for: spec) {
                    Text("next \(Fmt.rel(next))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !spec.enabled {
                    Text("paused")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                if running {
                    Button { store.stop(spec) } label: {
                        Image(systemName: "stop.fill")
                    }
                    .help("Stop this run")
                } else {
                    Button { store.runNow(spec) } label: {
                        Image(systemName: "play.fill")
                    }
                    .help("Run now")
                    Button { store.setEnabled(spec, !spec.enabled) } label: {
                        Image(systemName: spec.enabled ? "pause.fill" : "arrow.clockwise")
                    }
                    .help(spec.enabled ? "Pause schedule" : "Resume schedule")
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background(hovering ? Color.primary.opacity(0.06) : Color.clear)
        .overlay(alignment: .leading) {
            if let accent = paletteColor(spec.color) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(accent)
                    .frame(width: 3)
                    .padding(.vertical, 5)
                    .padding(.leading, 3)
            }
        }
        .onHover { hovering = $0 }
        .onTapGesture {
            let failed = jobStatus(spec, store: store) == .failed
            WindowRouter.shared.openManager(select: spec.id, tab: failed ? .runs : .config)
        }
    }
}

struct MenuBarIcon: View {
    @ObservedObject var store = JobStore.shared

    private var stateName: String {
        if store.hasUnseenFailure { return "failure" }
        if store.runningCount > 0 { return "running" }
        return "idle"
    }

    var body: some View {
        // Own glyph from the bundle (clock + spark, template image); SF Symbols
        // only when the binary runs outside the .app and has no resources.
        if let glyph = Bundle.main.image(forResource: "menubar-\(stateName)") {
            Image(nsImage: templated(glyph))
        } else if store.hasUnseenFailure {
            Image(systemName: "clock.badge.exclamationmark")
        } else if store.runningCount > 0 {
            Image(systemName: "clock.fill")
        } else {
            Image(systemName: "clock")
        }
    }

    private func templated(_ image: NSImage) -> NSImage {
        image.isTemplate = true
        return image
    }
}
