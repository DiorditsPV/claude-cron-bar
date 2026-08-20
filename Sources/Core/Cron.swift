import Foundation

public enum CronError: Error, LocalizedError, Equatable {
    case badFieldCount(Int)
    case badField(name: String, value: String)
    case badAlias(String)
    case tooManyIntervals(Int)

    public var errorDescription: String? {
        switch self {
        case .badFieldCount(let n):
            return "Expected 5 fields (min hour day month weekday), got \(n)"
        case .badField(let name, let value):
            return "Invalid \(name) field: \"\(value)\""
        case .badAlias(let alias):
            return "Unknown alias \"\(alias)\""
        case .tooManyIntervals(let n):
            return "Schedule expands to \(n) launchd intervals (limit 512); simplify it"
        }
    }
}

/// A parsed 5-field cron expression. `nil` field means wildcard.
/// Weekdays are normalized to 0-6 with 0 = Sunday (7 is accepted as Sunday).
public struct CronSchedule: Equatable, Sendable {
    public var minutes: [Int]?
    public var hours: [Int]?
    public var days: [Int]?
    public var months: [Int]?
    public var weekdays: [Int]?

    public init(minutes: [Int]? = nil, hours: [Int]? = nil, days: [Int]? = nil,
                months: [Int]? = nil, weekdays: [Int]? = nil) {
        self.minutes = minutes
        self.hours = hours
        self.days = days
        self.months = months
        self.weekdays = weekdays
    }

    static let aliases: [String: String] = [
        "@hourly": "0 * * * *",
        "@daily": "0 0 * * *",
        "@midnight": "0 0 * * *",
        "@weekly": "0 0 * * 0",
        "@monthly": "0 0 1 * *",
        "@yearly": "0 0 1 1 *",
        "@annually": "0 0 1 1 *",
    ]

    static let monthNames = ["JAN": 1, "FEB": 2, "MAR": 3, "APR": 4, "MAY": 5, "JUN": 6,
                             "JUL": 7, "AUG": 8, "SEP": 9, "OCT": 10, "NOV": 11, "DEC": 12]
    static let dayNames = ["SUN": 0, "MON": 1, "TUE": 2, "WED": 3, "THU": 4, "FRI": 5, "SAT": 6]

    public static func parse(_ expression: String) throws -> CronSchedule {
        var expr = expression.trimmingCharacters(in: .whitespaces)
        if expr.hasPrefix("@") {
            guard let expanded = aliases[expr.lowercased()] else { throw CronError.badAlias(expr) }
            expr = expanded
        }
        let fields = expr.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard fields.count == 5 else { throw CronError.badFieldCount(fields.count) }

        var s = CronSchedule()
        s.minutes = try parseField(fields[0], name: "minute", range: 0...59, names: [:])
        s.hours = try parseField(fields[1], name: "hour", range: 0...23, names: [:])
        s.days = try parseField(fields[2], name: "day", range: 1...31, names: [:])
        s.months = try parseField(fields[3], name: "month", range: 1...12, names: monthNames)
        s.weekdays = try parseField(fields[4], name: "weekday", range: 0...7, names: dayNames)
        if let w = s.weekdays {
            s.weekdays = Array(Set(w.map { $0 == 7 ? 0 : $0 })).sorted()
        }
        return s
    }

    static func parseField(_ field: String, name: String, range: ClosedRange<Int>,
                           names: [String: Int]) throws -> [Int]? {
        func value(_ token: String) throws -> Int {
            let upper = token.uppercased()
            if let v = names[upper] { return v }
            guard let v = Int(token), range.contains(v) else {
                throw CronError.badField(name: name, value: field)
            }
            return v
        }

        var out = Set<Int>()
        for term in field.split(separator: ",", omittingEmptySubsequences: false).map(String.init) {
            var body = term
            var step = 1
            if let slash = term.firstIndex(of: "/") {
                body = String(term[term.startIndex..<slash])
                guard let st = Int(term[term.index(after: slash)...]), st >= 1 else {
                    throw CronError.badField(name: name, value: field)
                }
                step = st
            }
            if body == "*" {
                if step == 1 { return nil }
                out.formUnion(stride(from: range.lowerBound, through: range.upperBound, by: step))
            } else if let dash = body.firstIndex(of: "-") {
                let lo = try value(String(body[body.startIndex..<dash]))
                let hi = try value(String(body[body.index(after: dash)...]))
                guard lo <= hi else { throw CronError.badField(name: name, value: field) }
                out.formUnion(stride(from: lo, through: hi, by: step))
            } else if body.isEmpty {
                throw CronError.badField(name: name, value: field)
            } else {
                out.insert(try value(body))
            }
        }
        guard !out.isEmpty else { throw CronError.badField(name: name, value: field) }
        return out.sorted()
    }

    /// Standard cron semantics: when both day-of-month and day-of-week are
    /// restricted, a date matches if EITHER matches.
    func dayMatches(dom: Int, weekday: Int) -> Bool {
        switch (days, weekdays) {
        case (nil, nil): return true
        case (let d?, nil): return d.contains(dom)
        case (nil, let w?): return w.contains(weekday)
        case (let d?, let w?): return d.contains(dom) || w.contains(weekday)
        }
    }

    public func nextDates(after date: Date, count: Int = 3,
                          calendar: Calendar = .current) -> [Date] {
        var results: [Date] = []
        var comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        comps.second = 0
        guard let floored = calendar.date(from: comps) else { return [] }
        let cursor = floored.addingTimeInterval(60)
        var day = calendar.startOfDay(for: cursor)
        let hourList = hours ?? Array(0...23)
        let minuteList = minutes ?? Array(0...59)

        for _ in 0..<(366 * 5) {
            let weekday = calendar.component(.weekday, from: day) - 1
            let dom = calendar.component(.day, from: day)
            let month = calendar.component(.month, from: day)
            if (months?.contains(month) ?? true) && dayMatches(dom: dom, weekday: weekday) {
                for h in hourList {
                    for m in minuteList {
                        guard let candidate = calendar.date(bySettingHour: h, minute: m,
                                                            second: 0, of: day),
                              candidate >= cursor else { continue }
                        results.append(candidate)
                        if results.count >= count { return results }
                    }
                }
            }
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = nextDay
        }
        return results
    }

    /// Expands the schedule into launchd StartCalendarInterval dictionaries.
    /// launchd ANDs Day and Weekday when both are present, so a schedule that
    /// restricts both is emitted as the union of day-only and weekday-only combos.
    public func launchdCalendarIntervals(limit: Int = 512) throws -> [[String: Int]] {
        func combos(day: [Int]?, weekday: [Int]?) -> [[String: Int]] {
            var dims: [(String, [Int])] = []
            if let v = minutes { dims.append(("Minute", v)) }
            if let v = hours { dims.append(("Hour", v)) }
            if let v = day { dims.append(("Day", v)) }
            if let v = months { dims.append(("Month", v)) }
            if let v = weekday { dims.append(("Weekday", v)) }
            var acc: [[String: Int]] = [[:]]
            for (key, values) in dims {
                acc = acc.flatMap { base in
                    values.map { var d = base; d[key] = $0; return d }
                }
            }
            return acc
        }

        let result: [[String: Int]]
        if days != nil && weekdays != nil {
            result = combos(day: days, weekday: nil) + combos(day: nil, weekday: weekdays)
        } else {
            result = combos(day: days, weekday: weekdays)
        }
        guard result.count <= limit else { throw CronError.tooManyIntervals(result.count) }
        return result
    }
}
