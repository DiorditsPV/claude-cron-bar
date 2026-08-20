import AppKit
import Combine
import Foundation

@MainActor
final class JobStore: ObservableObject {
    static let shared = JobStore()

    @Published var jobs: [JobSpec] = []
    @Published var runsByJob: [String: [Run]] = [:]
    @Published var lastError: String?

    private let launchd = LaunchdManager()
    private var backgroundTimer: Timer?
    private var panelTimer: Timer?
    private var spawned: [Process] = []
    private let defaults = UserDefaults.standard

    private let specEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let specDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {
        do {
            try Paths.ensureDirectories()
            installRunnerIfNeeded()
        } catch {
            lastError = "Setup failed: \(error.localizedDescription)"
        }
        loadJobs()
        reconcileAll()
        refresh(initial: true)
        backgroundTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in JobStore.shared.refresh() }
        }
    }

    // MARK: - Runner install

    private func installRunnerIfNeeded() {
        let url = Paths.runnerURL
        let current = try? String(contentsOf: url, encoding: .utf8)
        let desired = RunnerScript.contents + "\n"
        if current != desired {
            try? desired.write(to: url, atomically: true, encoding: .utf8)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: url.path)
    }

    // MARK: - Specs

    private var specURLs: [String: URL] = [:]

    /// The spec file's directory decides the group, so moving a file between
    /// group folders (e.g. from a Claude session) regroups the job.
    private func loadJobs() {
        var loaded: [JobSpec] = []
        var urls: [String: URL] = [:]
        for file in Paths.specFiles() {
            guard let data = try? Data(contentsOf: file),
                  var spec = try? specDecoder.decode(JobSpec.self, from: data) else { continue }
            spec.group = Paths.group(forSpecAt: file)
            loaded.append(spec)
            urls[spec.id] = file
        }
        jobs = loaded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        specURLs = urls
    }

    var existingGroups: [String] {
        Set(jobs.compactMap(\.group)).sorted()
    }

    private func removeGroupDirIfEmpty(_ url: URL) {
        let dir = url.deletingLastPathComponent()
        guard dir.standardizedFileURL.path != Paths.jobsDir.standardizedFileURL.path,
              let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
              contents.filter({ !$0.hasPrefix(".") }).isEmpty else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    func save(_ spec: JobSpec) throws {
        var spec = spec
        spec.updatedAt = Date()
        _ = try CronSchedule.parse(spec.schedule).launchdCalendarIntervals()

        let target = Paths.specURL(spec.id, group: spec.group)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try specEncoder.encode(spec)
        try data.write(to: target, options: .atomic)
        if let old = specURLs[spec.id],
           old.standardizedFileURL.path != target.standardizedFileURL.path {
            try? FileManager.default.removeItem(at: old)
            removeGroupDirIfEmpty(old)
        }
        specURLs[spec.id] = target

        launchd.bootout(id: spec.id)
        if spec.enabled {
            try launchd.writePlist(for: spec)
            try launchd.bootstrap(id: spec.id)
        } else {
            launchd.removePlist(id: spec.id)
        }

        if let idx = jobs.firstIndex(where: { $0.id == spec.id }) {
            jobs[idx] = spec
        } else {
            jobs.append(spec)
            jobs.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        refresh()
    }

    func delete(_ spec: JobSpec, deleteLogs: Bool) {
        launchd.bootout(id: spec.id)
        launchd.removePlist(id: spec.id)
        let url = specURLs[spec.id] ?? Paths.specURL(spec.id, group: spec.group)
        try? FileManager.default.removeItem(at: url)
        removeGroupDirIfEmpty(url)
        specURLs[spec.id] = nil
        if deleteLogs {
            try? FileManager.default.removeItem(at: Paths.jobLogsDir(spec.id))
        }
        jobs.removeAll { $0.id == spec.id }
        runsByJob[spec.id] = nil
    }

    func setEnabled(_ spec: JobSpec, _ enabled: Bool) {
        var updated = spec
        updated.enabled = enabled
        do {
            try save(updated)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Rewrites plists and aligns loaded state with specs. Leaves an untouched,
    /// already-loaded job alone so a run in progress is not interrupted.
    private func reconcileAll() {
        let fm = FileManager.default
        for spec in jobs {
            let plistURL = Paths.plistURL(spec.id)
            if spec.enabled {
                let before = try? Data(contentsOf: plistURL)
                guard (try? launchd.writePlist(for: spec)) != nil else { continue }
                let after = try? Data(contentsOf: plistURL)
                let changed = before != after
                if changed || !launchd.isLoaded(id: spec.id) {
                    launchd.bootout(id: spec.id)
                    try? launchd.bootstrap(id: spec.id)
                }
            } else {
                if launchd.isLoaded(id: spec.id) { launchd.bootout(id: spec.id) }
                if fm.fileExists(atPath: plistURL.path) { launchd.removePlist(id: spec.id) }
            }
        }
    }

    // MARK: - Runs & monitoring

    func refresh(initial: Bool = false) {
        var updated: [String: [Run]] = [:]
        for spec in jobs {
            updated[spec.id] = RunsLog.loadRuns(job: spec.id)
        }
        runsByJob = updated
        if initial {
            for spec in jobs where defaults.string(forKey: finishKey(spec.id)) == nil {
                let newest = updated[spec.id]?.first(where: { $0.end != nil })
                defaults.set(newest?.id ?? "-", forKey: finishKey(spec.id))
            }
        } else {
            detectFinishes()
        }
        spawned.removeAll { !$0.isRunning }
    }

    private func finishKey(_ id: String) -> String { "lastSeenFinish.\(id)" }

    private func detectFinishes() {
        for spec in jobs {
            guard let newest = runsByJob[spec.id]?.first(where: { $0.end != nil }) else { continue }
            let seen = defaults.string(forKey: finishKey(spec.id))
            guard newest.id != seen else { continue }
            defaults.set(newest.id, forKey: finishKey(spec.id))
            guard seen != nil else { continue }
            if newest.state == .failure {
                Notifier.post(title: spec.name,
                              body: "Run failed (exit \(newest.exitCode ?? -1))",
                              jobID: spec.id, runID: newest.id)
            } else if spec.notifyOnSuccess {
                Notifier.post(title: spec.name, body: "Run finished",
                              jobID: spec.id, runID: newest.id)
            }
        }
    }

    func runs(for id: String) -> [Run] { runsByJob[id] ?? [] }

    func latestRun(for id: String) -> Run? { runs(for: id).first }

    func isRunning(_ id: String) -> Bool {
        runs(for: id).contains { $0.state == .running }
    }

    var runningCount: Int { jobs.filter { isRunning($0.id) }.count }

    func nextRun(for spec: JobSpec) -> Date? {
        guard spec.enabled,
              let schedule = try? CronSchedule.parse(spec.schedule) else { return nil }
        return schedule.nextDates(after: Date(), count: 1).first
    }

    // MARK: - Failure badge

    private var failuresSeenAt: Date {
        Date(timeIntervalSince1970: defaults.double(forKey: "failuresSeenAt"))
    }

    var hasUnseenFailure: Bool {
        let seenAt = failuresSeenAt
        for runs in runsByJob.values {
            for run in runs {
                let stamp = run.end ?? run.start
                guard stamp > seenAt else { continue }
                if run.state == .failure || run.state == .interrupted { return true }
            }
        }
        return false
    }

    func markFailuresSeen() {
        defaults.set(Date().timeIntervalSince1970, forKey: "failuresSeenAt")
        objectWillChange.send()
    }

    // MARK: - Actions

    func runNow(_ spec: JobSpec) {
        if spec.enabled && launchd.isLoaded(id: spec.id) {
            do {
                try launchd.kickstart(id: spec.id)
            } catch {
                lastError = error.localizedDescription
            }
        } else {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", "exec \"$0\" \"$1\"",
                                 Paths.runnerURL.path, spec.id]
            do {
                try process.run()
                spawned.append(process)
            } catch {
                lastError = "Failed to start job: \(error.localizedDescription)"
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refresh() }
    }

    func stop(_ spec: JobSpec) {
        if launchd.isLoaded(id: spec.id) {
            launchd.terminate(id: spec.id)
        }
        for run in runs(for: spec.id) where run.state == .running {
            if let pid = run.pid { kill(pid_t(pid), SIGTERM) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refresh() }
    }

    func deleteRun(_ run: Run) {
        guard run.state != .running else { return }
        try? FileManager.default.removeItem(at: Paths.runDir(run.job, run: run.id))
        RunsLog.removeRuns(job: run.job, ids: [run.id])
        resyncFinishMarker(job: run.job)
        refresh()
    }

    func clearRuns(for spec: JobSpec) {
        let removable = runs(for: spec.id).filter { $0.state != .running }
        for run in removable {
            try? FileManager.default.removeItem(at: Paths.runDir(spec.id, run: run.id))
        }
        RunsLog.removeRuns(job: spec.id, ids: Set(removable.map(\.id)))
        resyncFinishMarker(job: spec.id)
        refresh()
    }

    /// Re-anchors the finish marker after run deletion so an older run
    /// resurfacing as "newest finished" is not announced as a fresh result.
    private func resyncFinishMarker(job: String) {
        let newest = RunsLog.loadRuns(job: job).first(where: { $0.end != nil })
        defaults.set(newest?.id ?? "-", forKey: finishKey(job))
    }

    // MARK: - Panel refresh cadence

    func reloadFromDisk() {
        loadJobs()
        reconcileAll()
    }

    private var panelObservers = 0

    func beginPanelRefresh() {
        panelObservers += 1
        reloadFromDisk()
        refresh()
        guard panelTimer == nil else { return }
        panelTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in JobStore.shared.refresh() }
        }
    }

    func endPanelRefresh() {
        panelObservers = max(0, panelObservers - 1)
        guard panelObservers == 0 else { return }
        panelTimer?.invalidate()
        panelTimer = nil
    }

    // MARK: - Sorting for display

    /// Ungrouped jobs first, then groups alphabetically; standard order within.
    var groupedJobs: [(group: String?, jobs: [JobSpec])] {
        let sorted = sortedJobs
        var result: [(group: String?, jobs: [JobSpec])] = []
        let ungrouped = sorted.filter { $0.group == nil }
        if !ungrouped.isEmpty { result.append((nil, ungrouped)) }
        for group in existingGroups {
            let members = sorted.filter { $0.group == group }
            if !members.isEmpty { result.append((group, members)) }
        }
        return result
    }

    var sortedJobs: [JobSpec] {
        jobs.sorted { a, b in
            let ra = isRunning(a.id), rb = isRunning(b.id)
            if ra != rb { return ra }
            if a.enabled != b.enabled { return a.enabled }
            let na = nextRun(for: a) ?? .distantFuture
            let nb = nextRun(for: b) ?? .distantFuture
            if na != nb { return na < nb }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}
