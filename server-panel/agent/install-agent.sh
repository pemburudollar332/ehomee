#!/usr/bin/env bash
# ehomee agent installer (Ubuntu/Debian)
# Auto-detect: root -> systemd system service; non-root -> systemd user service.
# Placeholder di-replace oleh /api/install.sh.php sebelum di-serve:
#   __PANEL_URL__, __ENROLL_TOKEN__, __AGENT_NAME__, __WATCH_DIR__

set -euo pipefail

PANEL_URL="${PANEL_URL:-__PANEL_URL__}"
ENROLL_TOKEN="${ENROLL_TOKEN:-__ENROLL_TOKEN__}"
AGENT_NAME="${AGENT_NAME:-__AGENT_NAME__}"
WATCH_DIR="${WATCH_DIR:-__WATCH_DIR__}"

if [[ -z "$PANEL_URL" || "$PANEL_URL" == __PANEL_URL__ ]]; then
  echo "PANEL_URL kosong — gunakan one-liner yang di-generate dari panel." >&2
  exit 1
fi
if [[ -z "$AGENT_NAME" ]]; then
  AGENT_NAME="$(hostname)"
fi

# ---- deteksi mode -------------------------------------------------------
if [[ $EUID -eq 0 ]]; then
  MODE=system
  AGENT_DIR="${AGENT_DIR:-/opt/ehomee-agent}"
  SERVICE_DIR="/etc/systemd/system"
  WANTED_BY="multi-user.target"
  SYSTEMCTL=(systemctl)
  EXTRA_SERVICE="User=root"
else
  MODE=user
  AGENT_DIR="${AGENT_DIR:-$HOME/.local/share/ehomee-agent}"
  SERVICE_DIR="$HOME/.config/systemd/user"
  WANTED_BY="default.target"
  SYSTEMCTL=(systemctl --user)
  EXTRA_SERVICE=""
  # default watch_dir yang masuk akal untuk user
  if [[ -z "${WATCH_DIR// }" || "$WATCH_DIR" == "/var/www/html" ]]; then
    WATCH_DIR="$HOME"
  fi
fi

echo ">> mode        : $MODE"
echo ">> user        : $(id -un) (uid=$EUID)"
echo ">> panel       : $PANEL_URL"
echo ">> agent name  : $AGENT_NAME"
echo ">> watch dir   : $WATCH_DIR"
echo ">> install dir : $AGENT_DIR"

# ---- dependencies -------------------------------------------------------
need_deps() {
  local miss=()
  command -v python3    >/dev/null 2>&1 || miss+=("python3")
  command -v curl       >/dev/null 2>&1 || miss+=("curl")
  command -v inotifywait>/dev/null 2>&1 || miss+=("inotify-tools")
  printf '%s\n' "${miss[@]}"
}

if [[ $MODE == system ]]; then
  export DEBIAN_FRONTEND=noninteractive
  echo ">> install dependencies..."
  apt-get update -qq
  apt-get install -y -qq python3 inotify-tools ca-certificates curl
else
  MISSING="$(need_deps | tr '\n' ' ' | sed 's/ $//')"
  if [[ -n "$MISSING" ]]; then
    echo ""
    echo "ERROR: dependency belum ada di sistem: $MISSING" >&2
    echo "       Mode user tidak bisa apt-install. Minta admin server ini untuk jalankan:" >&2
    echo "         sudo apt install -y python3 inotify-tools curl ca-certificates" >&2
    echo "       lalu ulangi one-liner ini." >&2
    exit 1
  fi
fi

mkdir -p "$AGENT_DIR" "$SERVICE_DIR"
mkdir -p "$WATCH_DIR" 2>/dev/null || true

# ---- fetch agent.py -----------------------------------------------------
echo ">> fetch agent.py..."
AGENT_PY_URL="${PANEL_URL%/}/api/agent.py.php"
curl -fsSL "$AGENT_PY_URL" -o "$AGENT_DIR/agent.py"
chmod 0755 "$AGENT_DIR/agent.py"

# ---- register -----------------------------------------------------------
echo ">> register agent ke panel..."
HOSTNAME_V="$(hostname)"
OS_V="$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-$NAME $VERSION}" || uname -a)"
ARCH_V="$(uname -m)"

REG_RESP="$(curl -fsSL -X POST \
  -H "X-Enroll-Token: $ENROLL_TOKEN" \
  --data-urlencode "name=$AGENT_NAME" \
  --data-urlencode "hostname=$HOSTNAME_V" \
  --data-urlencode "os=$OS_V" \
  --data-urlencode "arch=$ARCH_V" \
  --data-urlencode "watch_dir=$WATCH_DIR" \
  --data-urlencode "version=1.0" \
  "${PANEL_URL%/}/api/agent/register.php")"

AGENT_ID="$(printf '%s'  "$REG_RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("agent_id",""))')"
API_KEY="$(printf '%s'   "$REG_RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("api_key",""))')"
REPORT_URL="$(printf '%s' "$REG_RESP"| python3 -c 'import json,sys; print(json.load(sys.stdin).get("report_url",""))')"

if [[ -z "$AGENT_ID" || -z "$API_KEY" ]]; then
  echo "Gagal register. Response:" >&2
  echo "$REG_RESP" >&2
  exit 1
fi

# ---- config -------------------------------------------------------------
echo ">> tulis config..."
cat > "$AGENT_DIR/config.env" <<EOF
PANEL_URL=$PANEL_URL
REPORT_URL=$REPORT_URL
AGENT_ID=$AGENT_ID
API_KEY=$API_KEY
WATCH_DIR=$WATCH_DIR
INTERVAL=30
EOF
chmod 600 "$AGENT_DIR/config.env"

# ---- service unit -------------------------------------------------------
echo ">> systemd unit ($MODE mode)..."
SVC_PATH="$SERVICE_DIR/ehomee-agent.service"
cat > "$SVC_PATH" <<EOF
[Unit]
Description=ehomee remote agent ($AGENT_NAME)
After=network.target

[Service]
Type=simple
EnvironmentFile=$AGENT_DIR/config.env
ExecStart=/usr/bin/python3 $AGENT_DIR/agent.py
Restart=always
RestartSec=5
$EXTRA_SERVICE
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=$WANTED_BY
EOF

"${SYSTEMCTL[@]}" daemon-reload
"${SYSTEMCTL[@]}" enable --now ehomee-agent

sleep 2
"${SYSTEMCTL[@]}" status ehomee-agent --no-pager --lines=5 || true

# ---- user mode: enable linger supaya service jalan walau user logout ----
LINGER_NOTE=""
if [[ $MODE == user ]]; then
  if command -v loginctl >/dev/null 2>&1; then
    if loginctl show-user "$(id -un)" 2>/dev/null | grep -q '^Linger=yes'; then
      LINGER_NOTE="Linger sudah aktif. Service akan tetap jalan walau Anda logout."
    else
      if sudo -n true 2>/dev/null; then
        sudo loginctl enable-linger "$(id -un)" && \
          LINGER_NOTE="Linger diaktifkan otomatis. Service jalan walau Anda logout." || \
          LINGER_NOTE="Linger GAGAL diaktifkan. Jalankan manual sebagai root: sudo loginctl enable-linger $(id -un)"
      else
        LINGER_NOTE="Agent akan BERHENTI saat Anda logout. Jalankan sekali sebagai root: sudo loginctl enable-linger $(id -un)"
      fi
    fi
  fi
fi

STATUS_CMD=$([[ $MODE == system ]] && echo "systemctl status ehomee-agent" || echo "systemctl --user status ehomee-agent")
LOG_CMD=$([[ $MODE == system ]] && echo "journalctl -u ehomee-agent -f" || echo "journalctl --user -u ehomee-agent -f")

cat <<EOF

=========================================
 ehomee agent - terpasang ($MODE mode)
=========================================
 Agent ID : $AGENT_ID
 Name     : $AGENT_NAME
 User     : $(id -un)
 Panel    : $PANEL_URL
 Watch    : $WATCH_DIR
 Install  : $AGENT_DIR
 Service  : $STATUS_CMD
 Logs     : $LOG_CMD
EOF
[[ -n "$LINGER_NOTE" ]] && echo " Linger   : $LINGER_NOTE"
cat <<EOF

 Buka panel -> tab "Agents" untuk verifikasi.
=========================================
EOF
