#!/usr/bin/env bash
# ehomee-agent — pure bash edition.
# Tidak butuh Python3, hanya: bash + curl + find/stat/awk (built-in Linux).
# Fungsi sama dengan agent.py tapi lebih sederhana.
#
# Config disuntik dari config.env:
#   PANEL_URL, REPORT_URL, AGENT_ID, API_KEY, WATCH_DIR, INTERVAL, POLL_INTERVAL, POLL_MAX_FILES

set -eo pipefail

# ---- safety env ----
[[ -z "${HOME:-}" ]] && HOME="/tmp"
export PATH="${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"

# ---- validasi env wajib ----
: "${REPORT_URL:?REPORT_URL wajib}"
: "${AGENT_ID:?AGENT_ID wajib}"
: "${API_KEY:?API_KEY wajib}"
WATCH_DIR="${WATCH_DIR:-/var/www/html}"
INTERVAL="${INTERVAL:-30}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"
POLL_MAX_FILES="${POLL_MAX_FILES:-50000}"
UA="ehomee-agent-bash/1.0"

# ---- state ----
STATE_DIR="$(dirname "${BASH_SOURCE[0]}")"
SNAPSHOT_FILE="$STATE_DIR/.snapshot"
PENDING_EVENTS="$STATE_DIR/.events.pending"
: > "$PENDING_EVENTS"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >&2; }

# ---- json helpers ----
# Escape string untuk JSON (tanpa Python).
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"   # backslash
  s="${s//\"/\\\"}"   # double quote
  s="${s//	/\\t}"     # tab
  s="${s//
/\\n}"              # newline
  # buang kontrol karakter lain (ASCII < 0x20 selain yg sudah di-handle)
  s="$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')"
  printf '"%s"' "$s"
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ---- metrics ----
build_metrics_json() {
  local uptime_sec=0 cores=0
  local mem_total=0 mem_avail=0 mem_used=0
  local disk_total=0 disk_free=0 disk_used=0
  local load1=0 load5=0 load15=0
  local hostname_v
  hostname_v="$(hostname 2>/dev/null || uname -n 2>/dev/null || echo unknown)"

  # uptime
  if [[ -r /proc/uptime ]]; then
    uptime_sec="$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null || echo 0)"
  fi

  # loadavg
  if [[ -r /proc/loadavg ]]; then
    read -r load1 load5 load15 _ < /proc/loadavg
  fi

  # memory (dari /proc/meminfo, sudah dalam kB)
  if [[ -r /proc/meminfo ]]; then
    mem_total=$(awk '/^MemTotal:/     {print $2*1024; exit}' /proc/meminfo 2>/dev/null)
    mem_avail=$(awk '/^MemAvailable:/ {print $2*1024; exit}' /proc/meminfo 2>/dev/null)
    mem_total="${mem_total:-0}"
    mem_avail="${mem_avail:-0}"
    mem_used=$(( mem_total - mem_avail ))
    [[ $mem_used -lt 0 ]] && mem_used=0
  fi

  # disk (pakai df, bytes - pecah ke blocks*1024)
  if command -v df >/dev/null 2>&1; then
    local df_line
    df_line="$(df -P -B1 "$WATCH_DIR" 2>/dev/null | tail -1)"
    if [[ -n "$df_line" ]]; then
      # Filesystem 1B-blocks Used Available Capacity Mounted
      disk_total=$(awk '{print $2}' <<<"$df_line")
      disk_used=$(awk  '{print $3}' <<<"$df_line")
      disk_free=$(awk  '{print $4}' <<<"$df_line")
      disk_total="${disk_total:-0}"
      disk_used="${disk_used:-0}"
      disk_free="${disk_free:-0}"
    fi
  fi

  # cpu cores
  if [[ -r /proc/cpuinfo ]]; then
    cores=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 0)
  fi

  # JSON manual
  printf '{"ts":%s,"hostname":%s,"uptime_sec":%d,"loadavg":[%s,%s,%s],"memory":{"total":%d,"used":%d,"available":%d},"disk":{"path":%s,"total":%d,"used":%d,"free":%d},"cpu_cores":%d}' \
    "$(json_escape "$(now_iso)")" \
    "$(json_escape "$hostname_v")" \
    "$uptime_sec" \
    "$load1" "$load5" "$load15" \
    "$mem_total" "$mem_used" "$mem_avail" \
    "$(json_escape "$WATCH_DIR")" \
    "$disk_total" "$disk_used" "$disk_free" \
    "$cores"
}

# ---- events: polling via find + snapshot ----
scan_snapshot() {
  # Output: path<TAB>mtime<TAB>size
  find "$WATCH_DIR" \
    -maxdepth 20 \
    \( -name '.git' -o -name 'node_modules' -o -name '__pycache__' -o -name 'vendor' \) -prune -o \
    -type f -print 2>/dev/null | head -n "$POLL_MAX_FILES" | \
    while IFS= read -r f; do
      local stat_out
      stat_out="$(stat -c '%Y	%s' "$f" 2>/dev/null)" || continue
      printf '%s\t%s\n' "$f" "$stat_out"
    done
}

diff_snapshots() {
  local old="$1" new="$2" ts
  ts="$(now_iso)"

  # CREATE: path ada di new, tidak ada di old
  # DELETE: path ada di old, tidak ada di new
  # MODIFY: path ada di keduanya, tapi mtime/size beda
  # Pakai awk: baca old dulu ke array, lalu proses new
  awk -v ts="$ts" -v old="$old" -v pending="$PENDING_EVENTS" '
    BEGIN {
      while ((getline line < old) > 0) {
        split(line, a, "\t");
        old_map[a[1]] = a[2] "\t" a[3];
      }
      close(old);
    }
    {
      split($0, a, "\t");
      path = a[1]; meta = a[2] "\t" a[3];
      if (path in old_map) {
        if (old_map[path] != meta) {
          printf "{\"ts\":\"%s\",\"path\":\"%s\",\"event\":\"MODIFY\"}\n", ts, escape(path) >> pending;
        }
        delete old_map[path];
      } else {
        printf "{\"ts\":\"%s\",\"path\":\"%s\",\"event\":\"CREATE\"}\n", ts, escape(path) >> pending;
      }
    }
    END {
      for (p in old_map) {
        printf "{\"ts\":\"%s\",\"path\":\"%s\",\"event\":\"DELETE\"}\n", ts, escape(p) >> pending;
      }
    }
    function escape(s,   r) {
      r = s;
      gsub(/\\/, "\\\\", r);
      gsub(/"/, "\\\"", r);
      return r;
    }
  ' "$new"
}

collect_events_once() {
  local tmp_new
  tmp_new="$(mktemp)"
  scan_snapshot > "$tmp_new"
  if [[ -f "$SNAPSHOT_FILE" ]]; then
    diff_snapshots "$SNAPSHOT_FILE" "$tmp_new"
  fi
  mv "$tmp_new" "$SNAPSHOT_FILE"
}

# ---- send report ----
send_report() {
  local with_metrics="$1"   # 1 atau 0
  local body_file events_json events_count metrics_json

  events_count=0
  events_json="[]"
  if [[ -s "$PENDING_EVENTS" ]]; then
    # ambil max 200 event
    local batch
    batch="$(mktemp)"
    head -n 200 "$PENDING_EVENTS" > "$batch"
    events_count=$(wc -l < "$batch")
    # join jadi array
    events_json="[$(paste -sd, "$batch")]"
    # buang 200 baris pertama dari pending
    tail -n +201 "$PENDING_EVENTS" > "$PENDING_EVENTS.tmp" && mv "$PENDING_EVENTS.tmp" "$PENDING_EVENTS"
    rm -f "$batch"
  fi

  if [[ "$with_metrics" == "1" ]]; then
    metrics_json="$(build_metrics_json)"
  else
    metrics_json="null"
  fi

  body_file="$(mktemp)"
  printf '{"metrics":%s,"events":%s}' "$metrics_json" "$events_json" > "$body_file"

  local http_code
  http_code="$(curl -s -o /dev/null -w '%{http_code}' \
    --max-time 15 \
    -X POST \
    -H "Content-Type: application/json" \
    -H "X-Agent-Id: $AGENT_ID" \
    -H "Authorization: Bearer $API_KEY" \
    -H "User-Agent: $UA" \
    --data-binary "@$body_file" \
    "$REPORT_URL" 2>/dev/null)" || http_code="000"
  rm -f "$body_file"

  if [[ "$http_code" != "200" ]]; then
    log "report HTTP $http_code (events=$events_count metrics=$with_metrics)"
  fi
}

# ---- main ----
main() {
  log "start id=$AGENT_ID watch=$WATCH_DIR interval=${INTERVAL}s poll=${POLL_INTERVAL}s (pure bash)"

  # heartbeat pertama
  send_report 1
  local last_metric_ts
  last_metric_ts="$(date +%s)"

  # initial snapshot (tanpa diff, biar event pertama tidak blast semua file)
  scan_snapshot > "$SNAPSHOT_FILE"

  while true; do
    sleep "$POLL_INTERVAL"
    collect_events_once 2>/dev/null || true

    local now with_metrics=0
    now="$(date +%s)"
    if (( now - last_metric_ts >= INTERVAL )); then
      with_metrics=1
      last_metric_ts="$now"
    fi

    # kirim kalau ada event atau sudah waktunya metrics
    if [[ -s "$PENDING_EVENTS" || "$with_metrics" == "1" ]]; then
      send_report "$with_metrics"
    fi
  done
}

trap 'exit 0' INT TERM
main
