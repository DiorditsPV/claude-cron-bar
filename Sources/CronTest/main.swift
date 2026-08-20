import Foundation

var failures = 0

func check(_ condition: Bool, _ label: String) {
    if condition {
        print("ok  \(label)")
    } else {
        failures += 1
        print("FAIL \(label)")
    }
}

func parse(_ expr: String) -> CronSchedule? { try? CronSchedule.parse(expr) }

// Parsing
check(parse("0 9 * * *") == CronSchedule(minutes: [0], hours: [9], days: nil,
                                         months: nil, weekdays: nil),
      "daily at 9")
check(parse("*/15 * * * *")?.minutes == [0, 15, 30, 45], "*/15 minutes")
check(parse("0 9,14,18 * * 1-5")?.hours == [9, 14, 18], "hour list")
check(parse("0 9,14,18 * * 1-5")?.weekdays == [1, 2, 3, 4, 5], "weekday range")
check(parse("0 9 * * MON-FRI")?.weekdays == [1, 2, 3, 4, 5], "weekday names")
check(parse("0 0 * * 7")?.weekdays == [0], "7 normalized to Sunday")
check(parse("@daily") == parse("0 0 * * *"), "@daily alias")
check(parse("0 8-18/2 * * *")?.hours == [8, 10, 12, 14, 16, 18], "range with step")
check(parse("0 9 1 JAN *")?.months == [1], "month name")
check(parse("60 * * * *") == nil, "minute out of range rejected")
check(parse("0 9 * *") == nil, "4 fields rejected")
check(parse("@nope") == nil, "unknown alias rejected")
check(parse("a b c d e") == nil, "garbage rejected")

// Next dates (fixed reference: 2026-08-17 is a Monday)
var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
    calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

let ref = date(2026, 8, 17, 10, 30)
check(parse("0 9 * * *")!.nextDates(after: ref, count: 2, calendar: calendar)
        == [date(2026, 8, 18, 9, 0), date(2026, 8, 19, 9, 0)],
      "daily 9:00 from 10:30")
check(parse("45 10 * * *")!.nextDates(after: ref, count: 1, calendar: calendar)
        == [date(2026, 8, 17, 10, 45)],
      "same-day upcoming minute")
check(parse("30 10 * * *")!.nextDates(after: ref, count: 1, calendar: calendar)
        == [date(2026, 8, 18, 10, 30)],
      "current minute excluded")
check(parse("0 9,14,18 * * 1-5")!.nextDates(after: ref, count: 3, calendar: calendar)
        == [date(2026, 8, 17, 14, 0), date(2026, 8, 17, 18, 0), date(2026, 8, 18, 9, 0)],
      "weekday multi-hour sequence")
check(parse("0 9 * * 6,0")!.nextDates(after: ref, count: 2, calendar: calendar)
        == [date(2026, 8, 22, 9, 0), date(2026, 8, 23, 9, 0)],
      "weekend schedule from Monday")
// Cron OR rule: day-of-month 1 OR Monday
check(parse("0 9 1 * 1")!.nextDates(after: ref, count: 2, calendar: calendar)
        == [date(2026, 8, 24, 9, 0), date(2026, 8, 31, 9, 0)],
      "dom OR dow semantics")
check(parse("0 0 29 2 *")!.nextDates(after: ref, count: 1, calendar: calendar)
        == [date(2028, 2, 29, 0, 0)],
      "Feb 29 skips to leap year")

// launchd expansion
func intervals(_ expr: String) -> [[String: Int]] {
    (try? CronSchedule.parse(expr).launchdCalendarIntervals()) ?? []
}
check(intervals("0 9 * * *") == [["Minute": 0, "Hour": 9]], "simple daily interval")
check(intervals("*/30 * * * *").count == 2, "half-hourly two dicts")
check(intervals("0 9,14,18 * * 1-5").count == 15, "3 hours x 5 weekdays")
check(intervals("* * * * *") == [[:]], "wildcard -> single empty dict")
let orCase = intervals("0 9 1 * 1")
check(orCase.count == 2
        && orCase.contains(["Minute": 0, "Hour": 9, "Day": 1])
        && orCase.contains(["Minute": 0, "Hour": 9, "Weekday": 1]),
      "dom+dow expands to union")
check((try? CronSchedule.parse("0,15,30,45 9-12 * * *").launchdCalendarIntervals(limit: 10)) == nil,
      "interval limit enforced")

// Slug helpers
check(JobSpec.slugify("Daily Digest #1") == "daily-digest-1", "slugify")
check(JobSpec.isValidSlug("daily-digest"), "valid slug")
check(!JobSpec.isValidSlug("Daily"), "uppercase slug rejected")
check(!JobSpec.isValidSlug("-x"), "leading hyphen rejected")

// Spec decoding tolerance
let minimal = #"{"id": "t1", "schedule": "0 9 * * *"}"#
let decoded = try? JSONDecoder().decode(JobSpec.self, from: Data(minimal.utf8))
check(decoded?.kind == .claude && decoded?.skipPermissions == true
        && decoded?.enabled == true,
      "minimal spec decodes with defaults")

// Desktop import: frontmatter parsing
let skill = """
---
name: daily-report
description: runs every weekday at noon
---

Do the thing.
Second line.
"""
let parsed = DesktopImport.parseSkillMarkdown(skill)
check(parsed.name == "daily-report", "frontmatter name extracted")
check(parsed.body == "Do the thing.\nSecond line.", "frontmatter stripped from body")
let plain = DesktopImport.parseSkillMarkdown("Just a prompt.\n")
check(plain.name == nil && plain.body == "Just a prompt.", "no frontmatter passthrough")

// Desktop import: registry discovery and dedup by newest createdAt
let tmp = FileManager.default.temporaryDirectory
    .appendingPathComponent("cctest-import-\(getpid())")
let sessionA = tmp.appendingPathComponent("s1/w1")
let sessionB = tmp.appendingPathComponent("s2/w2")
try! FileManager.default.createDirectory(at: sessionA, withIntermediateDirectories: true)
try! FileManager.default.createDirectory(at: sessionB, withIntermediateDirectories: true)
let skillFile = tmp.appendingPathComponent("task.md")
try! skill.write(to: skillFile, atomically: true, encoding: .utf8)
let regA = """
{"scheduledTasks": [{"id": "daily-report", "cronExpression": "0 12 * * 1-5",
  "enabled": true, "filePath": "\(skillFile.path)", "createdAt": 100, "cwd": "/tmp"}]}
"""
let regB = """
{"scheduledTasks": [{"id": "daily-report", "cronExpression": "0 13 * * 1-5",
  "enabled": false, "filePath": "\(skillFile.path)", "createdAt": 200, "cwd": "/tmp"},
  {"id": "other", "cronExpression": "@daily", "filePath": "/nonexistent/skill.md"}]}
"""
try! regA.write(to: sessionA.appendingPathComponent("scheduled-tasks.json"),
                atomically: true, encoding: .utf8)
try! regB.write(to: sessionB.appendingPathComponent("scheduled-tasks.json"),
                atomically: true, encoding: .utf8)
let found = DesktopImport.findTasks(under: tmp)
check(found.count == 2, "two unique tasks found")
let digest = found.first { $0.id == "daily-report" }
check(digest?.cron == "0 13 * * 1-5", "newest registry entry wins")
check(digest?.name == "daily-report", "task name from frontmatter")
check(digest?.prompt == "Do the thing.\nSecond line.", "prompt from skill body")
check(digest?.sourceEnabled == false, "enabled flag carried over")
let other = found.first { $0.id == "other" }
check(other?.promptFileMissing == true, "missing prompt file flagged")
try? FileManager.default.removeItem(at: tmp)

// Groups
check(JobSpec.isValidGroup("work-reports"), "valid group name")
check(JobSpec.isValidGroup("Personal_2"), "group with underscore and case")
check(!JobSpec.isValidGroup("a/b"), "slash in group rejected")
check(!JobSpec.isValidGroup(""), "empty group rejected")

let cfgRoot = tmp.appendingPathComponent("cfg")
setenv("CLAUDE_CRON_CONFIG", cfgRoot.path, 1)
check(Paths.group(forSpecAt: Paths.jobsDir.appendingPathComponent("daily.json")) == nil,
      "root spec has no group")
check(Paths.group(forSpecAt: Paths.jobsDir.appendingPathComponent("work/daily.json")) == "work",
      "subdir spec derives group")
unsetenv("CLAUDE_CRON_CONFIG")

// Config file roundtrip
setenv("CLAUDE_CRON_CONFIG", cfgRoot.path, 1)
try! FileManager.default.createDirectory(at: cfgRoot, withIntermediateDirectories: true)
try! ConfigFile.save(AppConfig(telegram: TelegramConfig(botToken: "t0k", chatID: "42")))
let loadedCfg = ConfigFile.load()
check(loadedCfg.telegram?.botToken == "t0k" && loadedCfg.telegram?.chatID == "42",
      "config roundtrip")
check(TelegramConfig(botToken: "a", chatID: "b").resolvedAPIBase == "https://api.telegram.org",
      "default api base")
check(!TelegramConfig(botToken: "a", chatID: "").isConfigured, "empty chat = not configured")

// runs.jsonl deletion
setenv("CLAUDE_CRON_LOGS", tmp.appendingPathComponent("logs").path, 1)
try! FileManager.default.createDirectory(at: Paths.jobLogsDir("j1"),
                                         withIntermediateDirectories: true)
let journal = """
{"job":"j1","run":"r1","event":"start","ts":"2026-08-18T10:00:00+0300","pid":1}
{"job":"j1","run":"r1","event":"finish","ts":"2026-08-18T10:00:05+0300","exit":0,"duration":5}
{"job":"j1","run":"r2","event":"start","ts":"2026-08-18T11:00:00+0300","pid":2}
{"job":"j1","run":"r2","event":"finish","ts":"2026-08-18T11:00:07+0300","exit":1,"duration":7}
"""
try! journal.write(to: Paths.runsURL("j1"), atomically: true, encoding: .utf8)
check(RunsLog.loadRuns(job: "j1").count == 2, "two runs before delete")
RunsLog.removeRuns(job: "j1", ids: ["r1"])
let afterDelete = RunsLog.loadRuns(job: "j1")
check(afterDelete.count == 1 && afterDelete.first?.id == "r2", "run deleted from journal")
unsetenv("CLAUDE_CRON_LOGS")
unsetenv("CLAUDE_CRON_CONFIG")
try? FileManager.default.removeItem(at: tmp)

check(decoded?.telegramNotify == false, "telegramNotify defaults to false")

if failures > 0 {
    print("\n\(failures) failure(s)")
    exit(1)
}
print("\nall tests passed")
