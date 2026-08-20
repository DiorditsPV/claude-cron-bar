import Foundation
import SwiftUI

enum Fmt {
    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static func rel(_ date: Date) -> String {
        relative.localizedString(for: date, relativeTo: Date())
    }

    static func abs(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    static func duration(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return "\(h)h\(String(format: "%02d", m))m" }
        if m > 0 { return "\(m)m\(String(format: "%02d", s))s" }
        return "\(s)s"
    }
}

func paletteColor(_ name: String?) -> Color? {
    switch name {
    case "red": return .red
    case "orange": return .orange
    case "yellow": return .yellow
    case "green": return .green
    case "blue": return .blue
    case "purple": return .purple
    default: return nil
    }
}

enum JobStatus {
    case running
    case failed
    case ok
    case disabled

    var color: Color {
        switch self {
        case .running: return .blue
        case .failed: return .red
        case .ok: return .green
        case .disabled: return .secondary.opacity(0.5)
        }
    }
}

@MainActor
func jobStatus(_ spec: JobSpec, store: JobStore) -> JobStatus {
    if store.isRunning(spec.id) { return .running }
    if !spec.enabled { return .disabled }
    if let last = store.latestRun(for: spec.id),
       last.state == .failure || last.state == .interrupted { return .failed }
    return .ok
}

@MainActor
func lastRunSummary(_ spec: JobSpec, store: JobStore) -> String? {
    guard let run = store.latestRun(for: spec.id) else { return nil }
    switch run.state {
    case .running:
        return "running \(Fmt.duration(run.duration ?? 0))"
    case .success:
        return "last \u{2713} \(Fmt.rel(run.end ?? run.start)) \u{00b7} \(Fmt.duration(run.duration ?? 0))"
    case .failure:
        return "last \u{2717} \(Fmt.rel(run.end ?? run.start)) \u{00b7} exit \(run.exitCode ?? -1)"
    case .interrupted:
        return "last \u{2717} \(Fmt.rel(run.start)) \u{00b7} interrupted"
    }
}
