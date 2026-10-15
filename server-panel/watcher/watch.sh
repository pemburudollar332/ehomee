#!/usr/bin/env bash
# ehomee watcher - inotifywait → events.log + Telegram
# Dipanggil oleh systemd unit ehomee-watcher.service.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$DIR/../includes/config.local.php"

if [[ ! -f "$CFG" ]]; then
  echo "config.local.php tidak ada" >&2
  exit 1
fi

get() {
  php -r "\$c=require '$CFG'; echo \$c['$1'] ?? '';"
}

WATCH_DIR="$(get watch_dir)"
LOG="$(get events_log)"
TG_TOKEN="$(get telegram_bot_token)"
TG_CHAT="$(get telegram_chat_id)"

if [[ -z "$WATCH_DIR" || ! -d "$WATCH_DIR" ]]; then
  echo "watch_dir tidak valid: $WATCH_DIR" >&2
  exit 1
fi
mkdir -p "$(dirname "$LOG")"
touch "$LOG"

echo "[ehomee-watcher] watching $WATCH_DIR -> $LOG"

export LOG TG_TOKEN TG_CHAT

inotifywait -m -r \
  -e modify,create,delete,move,attrib \
  --timefmt '%Y-%m-%dT%H:%M:%SZ' \
  --format '%T|%w%f|%e' \
  "$WATCH_DIR" \
| python3 -u -c '
import sys, os, json, urllib.request, urllib.parse, time
log   = os.environ.get("LOG", "")
token = os.environ.get("TG_TOKEN", "")
chat  = os.environ.get("TG_CHAT", "")

def notify(text):
    if not token or not chat:
        return
    try:
        data = urllib.parse.urlencode({
            "chat_id": chat,
            "text": text,
            "disable_web_page_preview": "true",
        }).encode()
        req = urllib.request.Request(
            f"https://api.telegram.org/bot{token}/sendMessage",
            data=data,
        )
        urllib.request.urlopen(req, timeout=5).read()
    except Exception:
        pass

# debounce: kumpulkan path yang dimodifikasi dalam 2 detik
pending = {}
last_flush = time.time()

def flush():
    global pending, last_flush
    now = time.time()
    if not pending:
        last_flush = now
        return
    for path, evs in pending.items():
        ev_str = ",".join(sorted(evs))
        notify(f"[ehomee] {ev_str}\n{path}")
    pending = {}
    last_flush = now

try:
    f = open(log, "a", buffering=1)
    for line in sys.stdin:
        line = line.rstrip("\n")
        try:
            ts, path, ev = line.split("|", 2)
        except ValueError:
            continue
        rec = {"ts": ts, "path": path, "event": ev}
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        pending.setdefault(path, set()).add(ev)
        if time.time() - last_flush > 2:
            flush()
    flush()
finally:
    try: f.close()
    except Exception: pass
'
