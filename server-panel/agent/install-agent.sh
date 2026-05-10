#!/usr/bin/env bash
# ehomee agent installer — universal (jalan di user apa pun, auto-pilih metode).
# Metode yang didukung (auto-fallback berjenjang):
#   1. systemd-system (root)
#   2. systemd-user   (user biasa)
#   3. cron @reboot   (fallback kalau systemd-user mati / tidak ada linger)
#   4. nohup          (fallback terakhir, mis. di container tanpa systemd)
#
# Placeholder akan di-replace oleh /api/install.sh.php sebelum di-serve:
#   __PANEL_URL__, __ENROLL_TOKEN__, __AGENT_NAME__, __WATCH_DIR__, __METHOD__

# NOTE: sengaja TIDAK pakai 'set -u' — di beberapa environment (sudo bash, container
# minimal, cron, SSH tanpa env) variable seperti HOME bisa unset, dan -u akan crash.
set -eo pipefail

# ---- safety env: pastikan HOME selalu terdefinisi sebelum apa pun -------
if [[ -z "${HOME:-}" ]]; then
  HOME="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6)"
  [[ -z "$HOME" ]] && HOME="$(eval echo ~$(id -un) 2>/dev/null)"
  [[ -z "$HOME" ]] && HOME="/tmp"
  export HOME
fi
# pastikan PATH waras
export PATH="${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"

PANEL_URL="${PANEL_URL:-__PANEL_URL__}"
ENROLL_TOKEN="${ENROLL_TOKEN:-__ENROLL_TOKEN__}"
AGENT_NAME="${AGENT_NAME:-__AGENT_NAME__}"
WATCH_DIR="${WATCH_DIR:-__WATCH_DIR__}"
METHOD_REQUESTED="${METHOD:-__METHOD__}"

# Guard: placeholder marker di-rebuild supaya tidak ikut ter-replace oleh strtr.
# Kalau installer dijalankan tanpa di-serve via panel (placeholder mentah), tolak.
_PH_PREFIX="__PANEL"
_PH_URL="${_PH_PREFIX}_URL__"
_PH_METHOD="${_PH_PREFIX:0:2}METHOD__"
_PH_AGENT="${_PH_PREFIX:0:2}AGENT_NAME__"
_PH_WATCH="${_PH_PREFIX:0:2}WATCH_DIR__"

# default kalau placeholder masih utuh
if [[ "$METHOD_REQUESTED" == "$_PH_METHOD" || -z "$METHOD_REQUESTED" ]]; then
  METHOD_REQUESTED="auto"
fi

if [[ -z "$PANEL_URL" || "$PANEL_URL" == "$_PH_URL" ]]; then
  echo "PANEL_URL kosong — gunakan one-liner yang di-generate dari panel." >&2
  exit 1
fi
if [[ -z "$AGENT_NAME" || "$AGENT_NAME" == "$_PH_AGENT" ]]; then
  AGENT_NAME="$(hostname 2>/dev/null || uname -n 2>/dev/null || cat /etc/hostname 2>/dev/null || echo agent)"
fi

CURRENT_USER="$(id -un)"
IS_ROOT=0
[[ $EUID -eq 0 ]] && IS_ROOT=1

# ---- path install (selalu per-user kecuali root) -----------------------
if [[ $IS_ROOT -eq 1 ]]; then
  AGENT_DIR="${AGENT_DIR:-/opt/ehomee-agent}"
else
  AGENT_DIR="${AGENT_DIR:-$HOME/.local/share/ehomee-agent}"
fi

# ---- auto-detect watch dir ---------------------------------------------
# Kandidat: cek keberadaan + tidak kosong. Ambil yang pertama cocok.
detect_watch_dir() {
  local candidates=()
  if [[ $IS_ROOT -eq 1 ]]; then
    candidates+=(
      "/var/www/html"
      "/usr/share/nginx/html"
      "/srv/http"
      "/srv/www"
      "/var/www"
    )
    # cPanel-style: /home/*/public_html (ambil yang pertama ada & non-empty)
    for d in /home/*/public_html; do
      [[ -d "$d" ]] && candidates+=("$d")
    done
    # DirectAdmin-style: /home/*/domains/*/public_html
    for d in /home/*/domains/*/public_html; do
      [[ -d "$d" ]] && candidates+=("$d")
    done
  else
    candidates+=(
      "$HOME/public_html"
      "$HOME/www"
      "$HOME/htdocs"
      "$HOME/html"
      "$HOME/public"
    )
    # DirectAdmin per-domain
    for d in "$HOME"/domains/*/public_html; do
      [[ -d "$d" ]] && candidates+=("$d")
    done
    candidates+=("$HOME")
  fi

  # pilih yang ada + bukan kosong + bisa di-read
  for d in "${candidates[@]}"; do
    if [[ -d "$d" && -r "$d" ]]; then
      # preferensi: ada file di dalamnya (bukan folder kosong)
      if [[ -n "$(ls -A "$d" 2>/dev/null | head -1)" ]]; then
        echo "$d"
        return
      fi
    fi
  done
  # fallback: yang pertama ada walau kosong
  for d in "${candidates[@]}"; do
    [[ -d "$d" ]] && { echo "$d"; return; }
  done
  # fallback terakhir
  echo "${HOME:-/tmp}"
}

# Tentukan WATCH_DIR final
if [[ -z "${WATCH_DIR// }" || "$WATCH_DIR" == "auto" || "$WATCH_DIR" == "$_PH_WATCH" ]]; then
  WATCH_DIR="$(detect_watch_dir)"
  WATCH_AUTO=1
elif [[ "$WATCH_DIR" == '$HOME' ]]; then
  # user kirim '$HOME' literal (belum ter-expand) -> resolve
  WATCH_DIR="$HOME"
  WATCH_AUTO=0
elif [[ "$WATCH_DIR" == '$HOME/'* ]]; then
  # user kirim '$HOME/public_html' literal -> resolve
  WATCH_DIR="$HOME/${WATCH_DIR#\$HOME/}"
  WATCH_AUTO=0
else
  WATCH_AUTO=0
fi

# ---- deteksi kapabilitas sistem ----------------------------------------
has_systemd_system() {
  [[ $IS_ROOT -eq 1 ]] && command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}
has_systemd_user() {
  command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1
}
has_cron() {
  command -v crontab >/dev/null 2>&1 && (command -v cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1 || pgrep -x cron >/dev/null 2>&1 || true)
}

# ---- pilih method ------------------------------------------------------
pick_method() {
  case "$METHOD_REQUESTED" in
    auto)
      if has_systemd_system; then echo systemd-system
      elif has_systemd_user;  then echo systemd-user
      elif has_cron;          then echo cron
      else                         echo nohup
      fi
      ;;
    systemd-system|systemd-user|cron|nohup) echo "$METHOD_REQUESTED" ;;
    *) echo "METHOD tidak dikenal: $METHOD_REQUESTED" >&2; exit 2 ;;
  esac
}
METHOD="$(pick_method)"

# validasi method yang dipaksa tapi tidak didukung
case "$METHOD" in
  systemd-system) has_systemd_system || { echo "ERROR: systemd-system butuh root + systemd aktif." >&2; exit 2; } ;;
  systemd-user)   has_systemd_user   || { echo "ERROR: systemctl --user tidak tersedia. Coba METHOD=cron atau nohup." >&2; exit 2; } ;;
  cron)           has_cron           || { echo "ERROR: cron tidak ditemukan." >&2; exit 2; } ;;
esac

echo ">> panel        : $PANEL_URL"
echo ">> agent name   : $AGENT_NAME"
echo ">> user         : $CURRENT_USER (uid=$EUID)"
echo ">> method       : $METHOD"
echo ">> install dir  : $AGENT_DIR"
if [[ "${WATCH_AUTO:-0}" == "1" ]]; then
  echo ">> watch dir    : $WATCH_DIR  (auto-detected)"
else
  echo ">> watch dir    : $WATCH_DIR"
fi

# ---- dependencies ------------------------------------------------------
# HANYA python3 + curl yang WAJIB. inotify-tools opsional: kalau tidak ada,
# agent fallback ke polling murni Python.
need_deps_required() {
  local miss=()
  command -v python3 >/dev/null 2>&1 || miss+=("python3")
  command -v curl    >/dev/null 2>&1 || miss+=("curl")
  printf '%s\n' "${miss[@]}"
}
has_inotify() { command -v inotifywait >/dev/null 2>&1; }

if [[ $IS_ROOT -eq 1 ]]; then
  export DEBIAN_FRONTEND=noninteractive
  MISSING_REQ="$(need_deps_required | tr '\n' ' ' | sed 's/ $//')"
  if [[ -n "$MISSING_REQ" ]]; then
    if command -v apt-get >/dev/null 2>&1; then
      echo ">> install dependencies wajib (apt): $MISSING_REQ"
      apt-get update -qq
      # inotify-tools di-try (bonus) tapi tidak fatal kalau gagal
      apt-get install -y -qq python3 ca-certificates curl || true
      apt-get install -y -qq inotify-tools 2>/dev/null || echo "   (inotify-tools tidak terpasang — pakai polling)"
    elif command -v dnf >/dev/null 2>&1; then
      echo ">> install dependencies wajib (dnf)..."
      dnf install -y python3 ca-certificates curl || true
      dnf install -y inotify-tools 2>/dev/null || echo "   (inotify-tools tidak terpasang — pakai polling)"
    elif command -v yum >/dev/null 2>&1; then
      echo ">> install dependencies wajib (yum)..."
      yum install -y python3 ca-certificates curl || true
      yum install -y inotify-tools 2>/dev/null || echo "   (inotify-tools tidak terpasang — pakai polling)"
    elif command -v apk >/dev/null 2>&1; then
      echo ">> install dependencies wajib (apk)..."
      apk add --no-cache python3 ca-certificates curl || true
      apk add --no-cache inotify-tools 2>/dev/null || echo "   (inotify-tools tidak terpasang — pakai polling)"
    else
      echo "WARNING: package manager tidak terdeteksi. Pastikan python3 + curl tersedia." >&2
    fi
  else
    # semua wajib sudah ada; coba install inotify-tools sebagai bonus
    if ! has_inotify && command -v apt-get >/dev/null 2>&1; then
      apt-get install -y -qq inotify-tools 2>/dev/null || true
    fi
  fi
else
  MISSING_REQ="$(need_deps_required | tr '\n' ' ' | sed 's/ $//')"
  if [[ -n "$MISSING_REQ" ]]; then
    echo ""
    echo "ERROR: dependency wajib belum ada: $MISSING_REQ" >&2
    echo "       Agent butuh MINIMAL: python3 + curl. Minta admin jalankan sekali:" >&2
    echo "         sudo apt install -y python3 curl ca-certificates" >&2
    echo "         # atau: sudo dnf/yum/apk install python3 curl ca-certificates" >&2
    echo ""
    echo "       Catatan: inotify-tools TIDAK wajib (agent auto-fallback ke polling)." >&2
    exit 1
  fi
fi

# set WATCH_MODE otomatis kalau inotifywait tidak ada
if ! has_inotify; then
  WATCH_MODE_HINT="polling"
  echo ">> watcher mode : polling (inotify-tools tidak ada — pakai scan berkala)"
else
  WATCH_MODE_HINT="inotify"
  echo ">> watcher mode : inotify (real-time)"
fi

mkdir -p "$AGENT_DIR"
mkdir -p "$WATCH_DIR" 2>/dev/null || true

# ---- fetch agent.py ----------------------------------------------------
echo ">> fetch agent.py..."
curl -fsSL "${PANEL_URL%/}/api/agent.py.php" -o "$AGENT_DIR/agent.py"
chmod 0755 "$AGENT_DIR/agent.py"

# ---- register ke panel -------------------------------------------------
echo ">> register ke panel..."
HOSTNAME_V="$(hostname 2>/dev/null || uname -n 2>/dev/null || cat /etc/hostname 2>/dev/null || echo unknown)"
OS_V="$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-$NAME $VERSION}" || uname -a)"
ARCH_V="$(uname -m 2>/dev/null || echo unknown)"

REG_RESP="$(curl -fsSL -X POST \
  -H "X-Enroll-Token: $ENROLL_TOKEN" \
  --data-urlencode "name=$AGENT_NAME" \
  --data-urlencode "hostname=$HOSTNAME_V" \
  --data-urlencode "os=$OS_V" \
  --data-urlencode "arch=$ARCH_V" \
  --data-urlencode "watch_dir=$WATCH_DIR" \
  --data-urlencode "install_user=$CURRENT_USER" \
  --data-urlencode "install_method=$METHOD" \
  --data-urlencode "version=1.0" \
  "${PANEL_URL%/}/api/agent/register.php")"

AGENT_ID="$(printf  '%s' "$REG_RESP" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("agent_id",""))')"
API_KEY="$(printf   '%s' "$REG_RESP" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("api_key",""))')"
REPORT_URL="$(printf '%s' "$REG_RESP"| python3 -c 'import json,sys;print(json.load(sys.stdin).get("report_url",""))')"

if [[ -z "$AGENT_ID" || -z "$API_KEY" ]]; then
  echo "Gagal register. Response:" >&2
  echo "$REG_RESP" >&2
  exit 1
fi

# ---- config.env --------------------------------------------------------
cat > "$AGENT_DIR/config.env" <<EOF
PANEL_URL=$PANEL_URL
REPORT_URL=$REPORT_URL
AGENT_ID=$AGENT_ID
API_KEY=$API_KEY
WATCH_DIR=$WATCH_DIR
WATCH_MODE=${WATCH_MODE_HINT:-auto}
INTERVAL=30
POLL_INTERVAL=5
EOF
chmod 600 "$AGENT_DIR/config.env"

# ---- wrapper: agent-start.sh ------------------------------------------
# Dipakai oleh semua method supaya cara start konsisten.
cat > "$AGENT_DIR/agent-start.sh" <<'WRAP'
#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a
# shellcheck disable=SC1091
. "$DIR/config.env"
set +a
exec /usr/bin/python3 "$DIR/agent.py"
WRAP
chmod 0755 "$AGENT_DIR/agent-start.sh"

# ---- method-specific install ------------------------------------------
EXTRA_NOTE=""
case "$METHOD" in

  systemd-system)
    SVC="/etc/systemd/system/ehomee-agent.service"
    cat > "$SVC" <<EOF
[Unit]
Description=ehomee remote agent ($AGENT_NAME)
After=network.target

[Service]
Type=simple
ExecStart=$AGENT_DIR/agent-start.sh
Restart=always
RestartSec=5
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now ehomee-agent
    STATUS_CMD="systemctl status ehomee-agent"
    LOG_CMD="journalctl -u ehomee-agent -f"
    ;;

  systemd-user)
    mkdir -p "$HOME/.config/systemd/user"
    SVC="$HOME/.config/systemd/user/ehomee-agent.service"
    cat > "$SVC" <<EOF
[Unit]
Description=ehomee remote agent ($AGENT_NAME)
After=network.target

[Service]
Type=simple
ExecStart=$AGENT_DIR/agent-start.sh
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable --now ehomee-agent

    # linger: service tetap hidup saat user logout
    if command -v loginctl >/dev/null 2>&1; then
      if loginctl show-user "$CURRENT_USER" 2>/dev/null | grep -q '^Linger=yes'; then
        EXTRA_NOTE="Linger aktif — service jalan walau Anda logout."
      elif sudo -n true 2>/dev/null; then
        sudo loginctl enable-linger "$CURRENT_USER" \
          && EXTRA_NOTE="Linger diaktifkan otomatis." \
          || EXTRA_NOTE="Linger GAGAL. Jalankan: sudo loginctl enable-linger $CURRENT_USER"
      else
        EXTRA_NOTE="Agent BERHENTI saat logout. Minta admin jalankan: sudo loginctl enable-linger $CURRENT_USER"
      fi
    fi
    STATUS_CMD="systemctl --user status ehomee-agent"
    LOG_CMD="journalctl --user -u ehomee-agent -f"
    ;;

  cron)
    # crond.sh — supervise: kalau proses mati, restart; juga dipanggil @reboot
    SUP="$AGENT_DIR/agent-supervise.sh"
    PIDF="$AGENT_DIR/agent.pid"
    LOGF="$AGENT_DIR/agent.log"
    cat > "$SUP" <<EOF
#!/usr/bin/env bash
DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
PIDF="$PIDF"
LOGF="$LOGF"
# sudah jalan?
if [[ -f "\$PIDF" ]] && kill -0 "\$(cat "\$PIDF" 2>/dev/null)" 2>/dev/null; then
  exit 0
fi
# start baru
nohup "\$DIR/agent-start.sh" >> "\$LOGF" 2>&1 &
echo "\$!" > "\$PIDF"
EOF
    chmod 0755 "$SUP"

    # pasang crontab: @reboot + tiap menit supervise
    CRON_MARK="# ehomee-agent ($AGENT_ID)"
    TMP="$(mktemp)"
    (crontab -l 2>/dev/null | grep -v "$CRON_MARK" || true) > "$TMP"
    {
      echo "$CRON_MARK"
      echo "@reboot $SUP"
      echo "* * * * * $SUP"
    } >> "$TMP"
    crontab "$TMP"
    rm -f "$TMP"

    # start langsung
    "$SUP"
    sleep 1
    STATUS_CMD="cat $PIDF && ps -fp \$(cat $PIDF) || echo 'not running'"
    LOG_CMD="tail -f $LOGF"
    EXTRA_NOTE="Disupervise via cron tiap menit + @reboot. Log: $LOGF"
    ;;

  nohup)
    PIDF="$AGENT_DIR/agent.pid"
    LOGF="$AGENT_DIR/agent.log"
    # matikan dulu kalau ada
    if [[ -f "$PIDF" ]] && kill -0 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null; then
      kill "$(cat "$PIDF")" 2>/dev/null || true
      sleep 1
    fi
    nohup "$AGENT_DIR/agent-start.sh" >> "$LOGF" 2>&1 &
    echo "$!" > "$PIDF"
    STATUS_CMD="ps -fp \$(cat $PIDF)"
    LOG_CMD="tail -f $LOGF"
    EXTRA_NOTE="Mode nohup TIDAK auto-restart saat reboot. Untuk auto-start, pakai METHOD=cron."
    ;;
esac

# ---- uninstall script --------------------------------------------------
cat > "$AGENT_DIR/uninstall.sh" <<EOF
#!/usr/bin/env bash
set -u
METHOD="$METHOD"
AGENT_DIR="$AGENT_DIR"
AGENT_ID="$AGENT_ID"
case "\$METHOD" in
  systemd-system)
    systemctl disable --now ehomee-agent 2>/dev/null || true
    rm -f /etc/systemd/system/ehomee-agent.service
    systemctl daemon-reload
    ;;
  systemd-user)
    systemctl --user disable --now ehomee-agent 2>/dev/null || true
    rm -f "\$HOME/.config/systemd/user/ehomee-agent.service"
    systemctl --user daemon-reload
    ;;
  cron)
    (crontab -l 2>/dev/null | grep -v "ehomee-agent (\$AGENT_ID)" | grep -v "\$AGENT_DIR/agent-supervise.sh") | crontab -
    [[ -f "\$AGENT_DIR/agent.pid" ]] && kill "\$(cat "\$AGENT_DIR/agent.pid")" 2>/dev/null || true
    ;;
  nohup)
    [[ -f "\$AGENT_DIR/agent.pid" ]] && kill "\$(cat "\$AGENT_DIR/agent.pid")" 2>/dev/null || true
    ;;
esac
rm -rf "\$AGENT_DIR"
echo "ehomee-agent (\$METHOD) uninstalled."
EOF
chmod 0755 "$AGENT_DIR/uninstall.sh"

# ---- ringkasan ---------------------------------------------------------
cat <<EOF

=========================================
 ehomee agent TERPASANG
=========================================
 Method    : $METHOD
 Agent ID  : $AGENT_ID
 Name      : $AGENT_NAME
 User      : $CURRENT_USER
 Panel     : $PANEL_URL
 Watch     : $WATCH_DIR
 Install   : $AGENT_DIR
 Status    : $STATUS_CMD
 Logs      : $LOG_CMD
 Uninstall : $AGENT_DIR/uninstall.sh
EOF
[[ -n "$EXTRA_NOTE" ]] && echo " Note      : $EXTRA_NOTE"
cat <<EOF

 Buka panel -> tab "Agents" untuk verifikasi.
=========================================
EOF
