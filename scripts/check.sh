#!/usr/bin/env bash
# ehomee - website uptime monitor via curl
# Membaca sites.txt, cek tiap URL, tulis hasilnya ke data/status.json

set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITES_FILE="${ROOT_DIR}/sites.txt"
OUT_DIR="${ROOT_DIR}/data"
OUT_FILE="${OUT_DIR}/status.json"
HISTORY_FILE="${OUT_DIR}/history.json"

TIMEOUT="${TIMEOUT:-10}"       # detik
USER_AGENT="${USER_AGENT:-ehomee-monitor/1.0}"
MAX_HISTORY="${MAX_HISTORY:-288}"  # ~3 hari kalau tiap 15 menit

mkdir -p "${OUT_DIR}"

if [[ ! -f "${SITES_FILE}" ]]; then
  echo "ERROR: ${SITES_FILE} tidak ditemukan" >&2
  exit 1
fi

# JSON helpers (escape minimal) — printf '%s' supaya tidak menambah newline
json_escape() {
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

# Cek SSL expiry (hari tersisa). Kosong kalau bukan https atau gagal.
ssl_days_left() {
  local url="$1"
  [[ "$url" != https://* ]] && { echo ""; return; }
  local host port
  host="$(echo "$url" | awk -F/ '{print $3}' | awk -F: '{print $1}')"
  port="$(echo "$url" | awk -F/ '{print $3}' | awk -F: '{print ($2==""?443:$2)}')"
  local end_date
  end_date="$(echo | timeout 5 openssl s_client -servername "$host" -connect "${host}:${port}" 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//')"
  [[ -z "$end_date" ]] && { echo ""; return; }
  local end_ts now_ts diff
  end_ts="$(date -d "$end_date" +%s 2>/dev/null || echo "")"
  [[ -z "$end_ts" ]] && { echo ""; return; }
  now_ts="$(date +%s)"
  diff=$(( (end_ts - now_ts) / 86400 ))
  echo "$diff"
}

check_url() {
  local url="$1"
  local label="$2"

  # Format output curl: http_code|time_total|size_download|error
  local result http_code time_total size err status
  result="$(curl -sS -o /dev/null \
      -A "${USER_AGENT}" \
      --max-time "${TIMEOUT}" \
      -L \
      -w '%{http_code}|%{time_total}|%{size_download}' \
      "${url}" 2>/tmp/ehomee_err.$$)" && err="" || err="$(cat /tmp/ehomee_err.$$ 2>/dev/null || true)"
  rm -f "/tmp/ehomee_err.$$"

  if [[ -z "$result" ]]; then
    http_code="000"
    time_total="0"
    size="0"
  else
    IFS='|' read -r http_code time_total size <<<"$result"
  fi

  # Tentukan status: up jika 2xx/3xx
  if [[ "$http_code" =~ ^[23][0-9][0-9]$ ]]; then
    status="up"
  elif [[ "$http_code" == "000" ]]; then
    status="down"
  else
    status="degraded"
  fi

  local ssl_left
  ssl_left="$(ssl_days_left "$url")"

  # Build JSON object
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  printf '{"url":%s,"label":%s,"status":"%s","http_code":"%s","response_ms":%d,"size_bytes":%d,"ssl_days_left":%s,"error":%s,"checked_at":"%s"}' \
    "$(json_escape "$url")" \
    "$(json_escape "$label")" \
    "$status" \
    "$http_code" \
    "$(awk -v t="$time_total" 'BEGIN{printf "%d", t*1000}')" \
    "${size:-0}" \
    "${ssl_left:-null}" \
    "$(json_escape "${err:-}")" \
    "$ts"
}

# ---- main loop ----
results=()
while IFS= read -r line || [[ -n "$line" ]]; do
  # skip komentar / kosong
  [[ -z "${line// }" ]] && continue
  [[ "${line:0:1}" == "#" ]] && continue

  url="$(awk '{print $1}' <<<"$line")"
  label="$(awk '{$1=""; sub(/^ +/,""); print}' <<<"$line")"
  [[ -z "$label" ]] && label="$url"

  echo ">> check: $url" >&2
  obj="$(check_url "$url" "$label")"
  results+=("$obj")
done < "${SITES_FILE}"

generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
total="${#results[@]}"

# summary
up=0; down=0; degraded=0
for r in "${results[@]}"; do
  case "$(grep -oE '"status":"[^"]+"' <<<"$r" | head -n1 | cut -d'"' -f4)" in
    up) up=$((up+1));;
    down) down=$((down+1));;
    degraded) degraded=$((degraded+1));;
  esac
done

# gabungkan array JSON
joined="$(IFS=,; echo "${results[*]}")"

cat > "${OUT_FILE}" <<EOF
{
  "generated_at": "${generated_at}",
  "summary": { "total": ${total}, "up": ${up}, "down": ${down}, "degraded": ${degraded} },
  "checks": [${joined}]
}
EOF

echo "OK -> ${OUT_FILE} (up=${up} down=${down} degraded=${degraded})" >&2

# ---- append ke history.json (ring buffer sederhana) ----
python3 - "$OUT_FILE" "$HISTORY_FILE" "$MAX_HISTORY" <<'PY'
import json, sys, os
status_path, hist_path, max_n = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(status_path) as f:
    current = json.load(f)
hist = []
if os.path.exists(hist_path):
    try:
        with open(hist_path) as f:
            hist = json.load(f)
    except Exception:
        hist = []
entry = {
    "generated_at": current["generated_at"],
    "summary": current["summary"],
    "checks": [
        {"url": c["url"], "status": c["status"], "response_ms": c["response_ms"], "http_code": c["http_code"]}
        for c in current["checks"]
    ],
}
hist.append(entry)
hist = hist[-max_n:]
with open(hist_path, "w") as f:
    json.dump(hist, f)
PY
