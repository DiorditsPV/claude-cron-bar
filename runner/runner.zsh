#!/bin/zsh
# claude-cron job runner.
# Invoked by launchd via a login shell so PATH/proxy env from the user's
# profile applies. Records start/finish events to runs.jsonl, captures
# stdout to result.md and stderr to run.log, notifies on failure when the
# ClaudeCron app is not running to do it itself.
set -u

SLUG="${1:?usage: runner.zsh <job-id>}"
CONFIG_DIR="${CLAUDE_CRON_CONFIG:-$HOME/.config/claude-cron}"
LOGS_ROOT="${CLAUDE_CRON_LOGS:-$HOME/Library/Logs/claude-cron}"

# Login shells load .zshenv/.zprofile but not .zshrc, where user-level bin
# dirs are often added. Make the common ones visible to jobs regardless.
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
SPEC="$CONFIG_DIR/jobs/$SLUG.json"
if [[ ! -f "$SPEC" ]]; then
    group_matches=("$CONFIG_DIR"/jobs/*/"$SLUG".json(N))
    (( ${#group_matches[@]} > 0 )) && SPEC="${group_matches[1]}"
fi

[[ -f "$SPEC" ]] || { echo "spec not found: $SPEC" >&2; exit 78; }

eval "$(/usr/bin/python3 - "$SPEC" "$CONFIG_DIR/config.json" <<'PY'
import json, sys, shlex
spec = json.load(open(sys.argv[1]))
try:
    cfg = json.load(open(sys.argv[2]))
except Exception:
    cfg = {}
tg = cfg.get("telegram") or {}
def emit(key, value):
    print(f"{key}={shlex.quote(str(value))}")
emit("JOB_NAME", spec.get("name") or spec.get("id") or "job")
emit("JOB_KIND", spec.get("kind") or "claude")
emit("JOB_PROMPT", spec.get("prompt") or "")
emit("JOB_COMMAND", spec.get("command") or "")
emit("JOB_WORKDIR", spec.get("workdir") or "")
emit("JOB_MODEL", spec.get("model") or "")
emit("JOB_EFFORT", spec.get("effort") or "")
emit("JOB_EXTRA", spec.get("extraArgs") or "")
emit("JOB_SKIP_PERMS", "1" if spec.get("skipPermissions", True) else "0")
emit("JOB_NOTIFY_SUCCESS", "1" if spec.get("notifyOnSuccess") else "0")
emit("JOB_TG", "1" if spec.get("telegramNotify") else "0")
emit("TG_TOKEN", tg.get("botToken") or "")
emit("TG_CHAT", tg.get("chatID") or "")
emit("TG_API", (tg.get("apiBase") or "").strip() or "https://api.telegram.org")
emit("TG_PROXY", (tg.get("proxy") or "").strip())
PY
)"

RUN_ID="$(date +%Y%m%dT%H%M%S)-$$"
JOB_DIR="$LOGS_ROOT/$SLUG"
RUN_DIR="$JOB_DIR/$RUN_ID"
RUNS="$JOB_DIR/runs.jsonl"
mkdir -p "$RUN_DIR"

# Anything the job saves here is delivered to Telegram after a successful
# run (text files as messages, .tgh as an HTML-formatted message, the rest
# as documents) when telegramNotify is enabled; an empty outbox falls back
# to the stdout summary.
export CLAUDE_CRON_OUTBOX="$RUN_DIR/outbox"
mkdir -p "$CLAUDE_CRON_OUTBOX"

ts() { date "+%Y-%m-%dT%H:%M:%S%z" }
START_EPOCH=$(date +%s)
print -r -- "{\"job\":\"$SLUG\",\"run\":\"$RUN_ID\",\"event\":\"start\",\"ts\":\"$(ts)\",\"pid\":$$}" >> "$RUNS"

EXIT_CODE=1
finish() {
    local dur=$(( $(date +%s) - START_EPOCH ))
    print -r -- "{\"job\":\"$SLUG\",\"run\":\"$RUN_ID\",\"event\":\"finish\",\"ts\":\"$(ts)\",\"exit\":$EXIT_CODE,\"duration\":$dur}" >> "$RUNS"
    if [[ "$JOB_TG" == "1" && -n "$TG_TOKEN" && -n "$TG_CHAT" ]]; then
        JOB_NAME="$JOB_NAME" EXIT_CODE="$EXIT_CODE" DUR="$dur" RUN_DIR="$RUN_DIR" \
        TG_TOKEN="$TG_TOKEN" TG_CHAT="$TG_CHAT" TG_API="$TG_API" TG_PROXY="$TG_PROXY" \
        /usr/bin/python3 - >> "$RUN_DIR/run.log" 2>&1 <<'PY'
import html, json, os, re, time, urllib.request, uuid

exit_code = int(os.environ["EXIT_CODE"])
run_dir = os.environ["RUN_DIR"]
api = os.environ["TG_API"]
token = os.environ["TG_TOKEN"]
chat = os.environ["TG_CHAT"]

proxy = os.environ.get("TG_PROXY", "").strip()
if proxy:
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({"http": proxy, "https": proxy}))
else:
    opener = urllib.request.build_opener()

def read_tail(name, limit):
    try:
        with open(os.path.join(run_dir, name), encoding="utf-8", errors="replace") as f:
            return f.read()[-limit:]
    except Exception:
        return ""

def send_message(text, parse=None):
    payload = {"chat_id": chat, "text": text, "disable_web_page_preview": True}
    if parse:
        payload["parse_mode"] = parse
    request = urllib.request.Request(
        f"{api}/bot{token}/sendMessage",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"})
    opener.open(request, timeout=20)

TAG_RE = re.compile(r"<[^>]+>")

def send_html(text):
    # One bad entity would make Telegram reject the whole message, so a
    # rejected send is retried as plain text rather than lost.
    try:
        send_message(text, parse="HTML")
    except Exception as e:
        print(f"== telegram: html rejected ({e}), resending plain")
        send_message(html.unescape(TAG_RE.sub("", text)))

def send_document(path):
    boundary = "----claudecron" + uuid.uuid4().hex
    with open(path, "rb") as f:
        payload = f.read()
    body = (f"--{boundary}\r\nContent-Disposition: form-data; "
            f"name=\"chat_id\"\r\n\r\n{chat}\r\n").encode()
    body += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"document\"; "
             f"filename=\"{os.path.basename(path)}\"\r\n"
             f"Content-Type: application/octet-stream\r\n\r\n").encode()
    body += payload + f"\r\n--{boundary}--\r\n".encode()
    request = urllib.request.Request(
        f"{api}/bot{token}/sendDocument", data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    opener.open(request, timeout=120)

def chunk(text, limit=3800):
    parts = []
    while len(text) > limit:
        cut = text.rfind("\n\n", 0, limit)
        if cut < limit // 2:
            cut = text.rfind("\n", 0, limit)
        if cut < limit // 2:
            cut = limit
        parts.append(text[:cut].rstrip())
        text = text[cut:].lstrip("\n")
    if text.strip():
        parts.append(text)
    return parts or [""]

dur = int(os.environ["DUR"])
mins, secs = divmod(dur, 60)
took = f"{mins}m{secs:02d}s" if mins else f"{secs}s"
name = os.environ["JOB_NAME"]

TEXT_EXT = {".md", ".txt", ".text", ".log"}
# A .tgh file carries Telegram-flavoured HTML (<b>, <i>, <a href>): it is
# passed through untouched and switches the whole message to parse_mode
# HTML, which also means plain text files joining it have to be escaped.
HTML_EXT = {".tgh"}
outbox = os.path.join(run_dir, "outbox")
entries = []
if exit_code == 0 and os.path.isdir(outbox):
    entries = sorted(
        f for f in os.listdir(outbox)
        if not f.startswith(".") and os.path.isfile(os.path.join(outbox, f)))

sent = failed = 0

def attempt(what, fn, *args):
    global sent, failed
    try:
        fn(*args)
        sent += 1
    except Exception as e:
        failed += 1
        print(f"== telegram: {what} failed: {e}")

if entries:
    as_html = any(os.path.splitext(e)[1].lower() in HTML_EXT for e in entries)
    esc = (lambda s: html.escape(s, quote=False)) if as_html else (lambda s: s)
    stream = esc(f"✅ {name} · ok · {took}")
    docs = []
    for entry in entries:
        path = os.path.join(outbox, entry)
        ext = os.path.splitext(entry)[1].lower()
        if ext in TEXT_EXT or ext in HTML_EXT:
            try:
                with open(path, encoding="utf-8", errors="replace") as f:
                    body = f.read().strip()
                stream += "\n\n" + (body if ext in HTML_EXT else esc(body))
            except Exception as e:
                print(f"== telegram: cannot read {entry}: {e}")
        elif os.path.getsize(path) > 49_000_000:
            print(f"== telegram: {entry} skipped (over 50MB)")
        else:
            docs.append(path)
    send = send_html if as_html else send_message
    parts = chunk(stream)
    total = len(parts)
    for i, part in enumerate(parts, 1):
        if i > 1:
            time.sleep(1.1)
        attempt(f"message {i}/{total}", send,
                part if total == 1 else f"({i}/{total})\n{part}")
    for path in docs:
        time.sleep(1.1)
        attempt(f"document {os.path.basename(path)}", send_document, path)
else:
    result = read_tail("result.md", 6000).strip()
    if exit_code == 0:
        head = f"✅ {name} · ok · {took}"
        body = result or "(no output)"
    else:
        head = f"❌ {name} · exit {exit_code} · {took}"
        log_tail = "\n".join(read_tail("run.log", 4000).splitlines()[-15:])
        body = (result + "\n\n" if result else "") + "log tail:\n" + log_tail
    text = head + "\n\n" + body
    if len(text) > 3800:
        text = text[:3800] + "\n…(truncated)"
    attempt("message", send_message, text)

if failed == 0:
    print(f"== telegram: sent ({sent} item{'s' if sent != 1 else ''})")
PY
    fi
    if ! /usr/bin/pgrep -xq ClaudeCron; then
        local safe_name="${JOB_NAME//[\"\\\\]/}"
        if (( EXIT_CODE != 0 )); then
            /usr/bin/osascript -e "display notification \"$safe_name failed (exit $EXIT_CODE)\" with title \"ClaudeCron\"" >/dev/null 2>&1 || true
        elif [[ "$JOB_NOTIFY_SUCCESS" == "1" ]]; then
            /usr/bin/osascript -e "display notification \"$safe_name finished\" with title \"ClaudeCron\"" >/dev/null 2>&1 || true
        fi
    fi
}
trap finish EXIT

if [[ -n "$JOB_WORKDIR" ]]; then
    cd "$JOB_WORKDIR" || { echo "workdir missing: $JOB_WORKDIR" >&2; EXIT_CODE=79; exit 79; }
fi

if [[ "$JOB_KIND" == "shell" ]]; then
    cmd=(/bin/zsh -c "$JOB_COMMAND")
else
    CLAUDE_BIN="${CLAUDE_CRON_BIN:-claude}"
    if ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
        for candidate in "$HOME/.local/bin/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do
            [[ -x "$candidate" ]] && CLAUDE_BIN="$candidate" && break
        done
    fi
    command -v "$CLAUDE_BIN" >/dev/null 2>&1 || { echo "claude binary not found (set CLAUDE_CRON_BIN)" >&2; EXIT_CODE=80; exit 80; }

    cmd=("$CLAUDE_BIN" -p "$JOB_PROMPT")
    [[ -n "$JOB_MODEL" ]] && cmd+=(--model "$JOB_MODEL")
    [[ -n "$JOB_EFFORT" ]] && cmd+=(--effort "$JOB_EFFORT")
    [[ "$JOB_SKIP_PERMS" == "1" ]] && cmd+=(--dangerously-skip-permissions)
    [[ -n "$JOB_EXTRA" ]] && cmd+=(${(z)JOB_EXTRA})
fi

{
    echo "== claude-cron run $RUN_ID"
    echo "== job: $SLUG ($JOB_KIND)"
    echo "== cwd: ${JOB_WORKDIR:-$PWD}"
    echo "== cmd: ${(q-)cmd[@]}"
} >> "$RUN_DIR/run.log"

"${cmd[@]}" > "$RUN_DIR/result.md" 2>> "$RUN_DIR/run.log" &
CHILD=$!
trap 'kill -TERM $CHILD 2>/dev/null' TERM INT
wait $CHILD
EXIT_CODE=$?
wait $CHILD 2>/dev/null || true
exit $EXIT_CODE
