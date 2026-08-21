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
# Delivery is two independent switches; a spec from before them carries
# telegramNotify, which meant "status and output".
legacy = spec.get("telegramNotify")
emit("JOB_TG_STATUS", "1" if spec.get("telegramStatus", legacy) else "0")
emit("JOB_TG_OUTPUT", "1" if spec.get("telegramOutput", legacy) else "0")
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

# Files the job saves here ride along to Telegram after a successful run, as
# attachments, when delivery of the output is enabled. The message itself is
# the job's own output - the outbox is for files, not for text.
export CLAUDE_CRON_OUTBOX="$RUN_DIR/outbox"
mkdir -p "$CLAUDE_CRON_OUTBOX"

ts() { date "+%Y-%m-%dT%H:%M:%S%z" }
START_EPOCH=$(date +%s)
print -r -- "{\"job\":\"$SLUG\",\"run\":\"$RUN_ID\",\"event\":\"start\",\"ts\":\"$(ts)\",\"pid\":$$}" >> "$RUNS"

EXIT_CODE=1
finish() {
    local dur=$(( $(date +%s) - START_EPOCH ))
    print -r -- "{\"job\":\"$SLUG\",\"run\":\"$RUN_ID\",\"event\":\"finish\",\"ts\":\"$(ts)\",\"exit\":$EXIT_CODE,\"duration\":$dur}" >> "$RUNS"
    # A failure is louder than the preset: a job that broke is reported even
    # when both switches are off, otherwise a scheduled job can fail in silence.
    if [[ ( "$JOB_TG_STATUS" == "1" || "$JOB_TG_OUTPUT" == "1" || $EXIT_CODE -ne 0 ) \
          && -n "$TG_TOKEN" && -n "$TG_CHAT" ]]; then
        JOB_NAME="$JOB_NAME" EXIT_CODE="$EXIT_CODE" DUR="$dur" RUN_DIR="$RUN_DIR" \
        TG_STATUS="$JOB_TG_STATUS" TG_OUTPUT="$JOB_TG_OUTPUT" \
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

# --- markdown -> Telegram HTML ------------------------------------------------
#
# Telegram accepts a short whitelist of tags, and one stray "<" or "&" makes it
# reject the whole message. So: pull code out first (it must survive verbatim),
# escape everything else, then turn a small markdown subset into tags. Doing it
# here rather than in the job's prompt is the point - a prompt should describe
# the work, not the transport.

FENCE_RE = re.compile(r"```[^\n]*\n(.*?)\n?```", re.S)
INLINE_CODE_RE = re.compile(r"`([^`\n]+)`")
LINK_RE = re.compile(r"\[([^\]\n]+)\]\((https?://[^)\s]+)\)")
BOLD_RE = re.compile(r"\*\*([^*\n]+)\*\*")
ITALIC_RE = re.compile(r"(?<![*\w])\*([^*\n]+)\*(?!\w)")
UNDER_ITALIC_RE = re.compile(r"(?<![_\w])_([^_\n]+)_(?!\w)")
HEADING_RE = re.compile(r"(?m)^#{1,6}[ \t]+(.+)$")

def md_to_html(text):
    kept = []

    def keep(fragment):
        kept.append(fragment)
        return f"\x00{len(kept) - 1}\x00"

    text = FENCE_RE.sub(
        lambda m: keep("<pre>" + html.escape(m.group(1), quote=False) + "</pre>"), text)
    text = INLINE_CODE_RE.sub(
        lambda m: keep("<code>" + html.escape(m.group(1), quote=False) + "</code>"), text)

    text = html.escape(text, quote=False)

    text = LINK_RE.sub(lambda m: keep(f'<a href="{m.group(2)}">{m.group(1)}</a>'), text)
    text = BOLD_RE.sub(r"<b>\1</b>", text)
    text = ITALIC_RE.sub(r"<i>\1</i>", text)
    text = UNDER_ITALIC_RE.sub(r"<i>\1</i>", text)
    text = HEADING_RE.sub(r"<b>\1</b>", text)

    for i, fragment in enumerate(kept):
        text = text.replace(f"\x00{i}\x00", fragment)
    return text


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

want_status = os.environ.get("TG_STATUS") == "1"
want_output = os.environ.get("TG_OUTPUT") == "1"

outbox = os.path.join(run_dir, "outbox")
attachments = []
if exit_code == 0 and want_output and os.path.isdir(outbox):
    attachments = [
        os.path.join(outbox, f) for f in sorted(os.listdir(outbox))
        if not f.startswith(".") and os.path.isfile(os.path.join(outbox, f))]

sent = failed = 0

def attempt(what, fn, *args):
    global sent, failed
    try:
        fn(*args)
        sent += 1
    except Exception as e:
        failed += 1
        print(f"== telegram: {what} failed: {e}")

# --- what goes out -----------------------------------------------------------
#
# The job prints what a human should read; nothing in its prompt knows about
# Telegram. Markup is this script's job: a small markdown subset becomes
# Telegram HTML and everything else is escaped, so a stray "<" or "&" in the
# output cannot make the API reject the message.

status_line = (f"✅ {name} · ok · {took}" if exit_code == 0
               else f"❌ {name} · exit {exit_code} · {took}")

if exit_code == 0:
    body_md = read_tail("result.md", 6000).strip() if want_output else ""
else:
    # A failure carries its evidence regardless of the switches.
    result = read_tail("result.md", 6000).strip()
    log_tail = "\n".join(read_tail("run.log", 4000).splitlines()[-15:])
    body_md = (result + "\n\n" if result else "") + "log tail:\n" + log_tail

pieces = []
if want_status or exit_code != 0:
    pieces.append(md_to_html(status_line))
if body_md:
    pieces.append(md_to_html(body_md))

if pieces:
    parts = chunk("\n\n".join(pieces))
    total = len(parts)
    for i, part in enumerate(parts, 1):
        if i > 1:
            time.sleep(1.1)
        attempt(f"message {i}/{total}", send_html,
                part if total == 1 else f"({i}/{total})\n{part}")

for path in attachments:
    if os.path.getsize(path) > 49_000_000:
        print(f"== telegram: {os.path.basename(path)} skipped (over 50MB)")
        continue
    time.sleep(1.1)
    attempt(f"document {os.path.basename(path)}", send_document, path)

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
