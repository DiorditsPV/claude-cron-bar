import Foundation

public enum RunsLog {
    struct Event: Decodable {
        let job: String
        let run: String
        let event: String
        let ts: String
        let pid: Int?
        let exit: Int?
    }

    static let tsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return f
    }()

    /// Parses the tail of a job's runs.jsonl into Run values, newest first.
    public static func loadRuns(job: String, maxEvents: Int = 400) -> [Run] {
        guard let data = try? Data(contentsOf: Paths.runsURL(job)),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n").suffix(maxEvents)

        var runs: [String: Run] = [:]
        var order: [String] = []
        let decoder = JSONDecoder()
        for line in lines {
            guard let event = try? decoder.decode(Event.self, from: Data(line.utf8)),
                  let date = tsFormatter.date(from: event.ts) else { continue }
            switch event.event {
            case "start":
                if runs[event.run] == nil { order.append(event.run) }
                runs[event.run] = Run(id: event.run, job: job, start: date, pid: event.pid)
            case "finish":
                if var run = runs[event.run] {
                    run.end = date
                    run.exitCode = event.exit
                    runs[event.run] = run
                } else {
                    // Start record fell outside the tail window.
                    order.append(event.run)
                    runs[event.run] = Run(id: event.run, job: job, start: date,
                                          end: date, exitCode: event.exit)
                }
            default:
                continue
            }
        }
        return order.compactMap { runs[$0] }.sorted { $0.start > $1.start }
    }

    /// Rewrites a job's runs.jsonl without the given run ids.
    public static func removeRuns(job: String, ids: Set<String>) {
        let url = Paths.runsURL(job)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        let kept = text.split(separator: "\n").filter { line in
            guard let event = try? decoder.decode(Event.self, from: Data(line.utf8)) else {
                return false
            }
            return !ids.contains(event.run)
        }
        let output = kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
        try? output.write(to: url, atomically: true, encoding: .utf8)
    }
}
