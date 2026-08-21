#!/usr/bin/env python3
"""Seed a throwaway ClaudeCron config with sample jobs and run history.

Used by `make demo`, which launches a sandboxed instance against it: the
sandbox never registers anything with launchd, so a demo run cannot touch
the real user domain. Handy for screenshots and for trying the UI out
without scheduling anything.
"""
import json
import os
import shutil
import sys
from datetime import datetime, timedelta

root = os.path.abspath(sys.argv[1])
jobs_dir = os.path.join(root, "config", "jobs")
logs_dir = os.path.join(root, "logs")
shutil.rmtree(root, ignore_errors=True)

JOBS = [
    {
        "id": "daily-standup", "name": "Daily standup", "group": "reports",
        "color": "blue", "kind": "claude", "schedule": "0 9 * * 1-5",
        "prompt": "Summarize yesterday's commits across my active repositories "
                  "into a short standup update: what moved, what is blocked, "
                  "what I plan to pick up next. Finish with a three-line summary.",
        "workdir": "~/dev", "tgStatus": True, "tgOutput": True, "notifyOnSuccess": False,
        "model": "sonnet", "effort": None,
    },
    {
        "id": "weekly-review", "name": "Weekly review", "group": "reports",
        "color": "purple", "kind": "claude", "schedule": "0 17 * * 5",
        "prompt": "Build a weekly review from this week's work: shipped items, "
                  "open threads, and anything that slipped. Save the report as "
                  "$CLAUDE_CRON_OUTBOX/01-review.md so it lands in Telegram.",
        "workdir": "~/dev", "tgStatus": True, "tgOutput": True, "notifyOnSuccess": False,
        "model": None, "effort": "high",
    },
    {
        "id": "repo-sync", "name": "Repo sync", "group": "maintenance",
        "color": "green", "kind": "shell", "schedule": "*/30 * * * *",
        "command": "git -C ~/dev/notes pull --ff-only && echo synced",
        "workdir": "~/dev", "tgStatus": True, "tgOutput": False, "notifyOnSuccess": False,
        "model": None, "effort": None,
    },
    {
        "id": "dependency-audit", "name": "Dependency audit", "group": "maintenance",
        "color": "orange", "kind": "claude", "schedule": "0 3 * * 1",
        "prompt": "Audit dependencies for known advisories and pins that drifted. "
                  "Report only actionable findings, newest advisories first.",
        "workdir": "~/dev", "tgStatus": False, "tgOutput": False, "notifyOnSuccess": True,
        "model": None, "effort": None,
    },
    {
        "id": "inbox-triage", "name": "Inbox triage", "group": None,
        "color": None, "kind": "claude", "schedule": "0 */4 * * *",
        "prompt": "Triage my notes inbox: file each new note under the right "
                  "topic, merge duplicates, and list anything that needs a decision.",
        "workdir": "~/dev", "tgStatus": True, "tgOutput": False, "notifyOnSuccess": False,
        "model": "haiku", "effort": "low",
    },
]

# (job id, minutes ago, duration seconds, exit code)
HISTORY = [
    ("daily-standup", 95, 134, 0),
    ("daily-standup", 1535, 128, 0),
    ("daily-standup", 2975, 141, 0),
    ("weekly-review", 4400, 512, 0),
    ("repo-sync", 12, 3, 0),
    ("repo-sync", 42, 4, 0),
    ("repo-sync", 72, 2, 0),
    ("dependency-audit", 380, 46, 1),
    ("dependency-audit", 10460, 64, 0),
    ("inbox-triage", 205, 71, 0),
]

RESULTS = {
    "daily-standup": "Standup for Tuesday\n\n- Shipped: outbox delivery, run "
                     "history pruning\n- In flight: schedule editor validation\n"
                     "- Blocked: nothing\n",
    "weekly-review": "Weekly review saved to the outbox: 14 commits across 3 "
                     "repositories, 2 open threads carried into next week.\n",
    "repo-sync": "synced\n",
    "dependency-audit": "",
    "inbox-triage": "Filed 6 notes, merged 2 duplicates, 1 note needs a "
                    "decision: whether to keep the legacy export path.\n",
}

LOGS = {
    "dependency-audit": "npm error code E401\nnpm error Incorrect or missing "
                        "password.\nadvisory feed unreachable, aborting audit\n",
}

now = datetime.now().astimezone()
os.makedirs(jobs_dir, exist_ok=True)

for job in JOBS:
    spec = {
        "id": job["id"], "name": job["name"], "kind": job["kind"],
        "prompt": job.get("prompt", ""), "command": job.get("command", ""),
        "workdir": os.path.expanduser(job["workdir"]),
        "schedule": job["schedule"], "model": job["model"],
        "effort": job["effort"], "extraArgs": "", "skipPermissions": True,
        "notifyOnSuccess": job["notifyOnSuccess"],
        "telegramStatus": job["tgStatus"], "telegramOutput": job["tgOutput"],
        "enabled": True,
        "color": job["color"],
        "createdAt": (now - timedelta(days=30)).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "updatedAt": (now - timedelta(days=2)).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    target_dir = os.path.join(jobs_dir, job["group"]) if job["group"] else jobs_dir
    os.makedirs(target_dir, exist_ok=True)
    with open(os.path.join(target_dir, job["id"] + ".json"), "w") as f:
        json.dump(spec, f, indent=2, sort_keys=True, ensure_ascii=False)

journals = {}
for job_id, ago, duration, code in sorted(HISTORY, key=lambda h: -h[1]):
    start = now - timedelta(minutes=ago)
    end = start + timedelta(seconds=duration)
    run_id = start.strftime("%Y%m%dT%H%M%S") + f"-{1000 + ago}"
    stamp = lambda d: d.strftime("%Y-%m-%dT%H:%M:%S%z")
    journals.setdefault(job_id, []).extend([
        {"job": job_id, "run": run_id, "event": "start",
         "ts": stamp(start), "pid": 1000 + ago},
        {"job": job_id, "run": run_id, "event": "finish", "ts": stamp(end),
         "exit": code, "duration": duration},
    ])
    run_dir = os.path.join(logs_dir, job_id, run_id)
    os.makedirs(os.path.join(run_dir, "outbox"), exist_ok=True)
    with open(os.path.join(run_dir, "result.md"), "w") as f:
        f.write(RESULTS.get(job_id, ""))
    with open(os.path.join(run_dir, "run.log"), "w") as f:
        f.write(f"== claude-cron run {run_id}\n== job: {job_id}\n"
                f"== cwd: {os.path.expanduser('~/dev')}\n")
        f.write(LOGS.get(job_id, "") if code else "")

for job_id, events in journals.items():
    with open(os.path.join(logs_dir, job_id, "runs.jsonl"), "w") as f:
        for event in events:
            f.write(json.dumps(event) + "\n")

os.makedirs(os.path.join(root, "agents"), exist_ok=True)
print(f"seeded {len(JOBS)} demo jobs and {len(HISTORY)} runs in {root}")
