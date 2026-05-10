#!/usr/bin/env bash
# ehomee agent installer (Ubuntu/Debian)
# Placeholder di-replace oleh /api/install.sh.php sebelum di-serve:
#   __PANEL_URL__, __ENROLL_TOKEN__, __AGENT_NAME__, __WATCH_DIR__

set -euo pipefail

PANEL_URL="${PANEL_URL:-__PANEL_URL__}"
ENROLL_TOKEN="${ENROLL_TOKEN:-__ENROLL_TOKEN__}"
AGENT_NAME="${AGENT_NAME:-__AGENT_NAME__}"
WATCH_DIR="${WATCH_DIR:-__WATCH_DIR__}"
AGENT_DIR="${AGENT_DIR:-/opt/ehomee-agent}"

if [[ $EUID -ne 0 ]]; then
  echo "Harus dijalankan sebagai root (sudo)." >&2
  exit 1
fi
if [[ -z "$PANEL_URL" || "$PANEL_URL" == __PANEL_URL__ ]]; then
  echo "PANEL_URL kosong — gunakan one-liner yang di-generate dari panel." >&2
  exit 1
fi
if [[ -z "$AGENT_NAME" ]]; then
  AGENT_NAME="$(hostname)"
fi

echo ">> panel       : $PANEL_URL"
echo ">> agent name  : $AGENT_NAME"
echo ">> watch dir   : $WATCH_DIR"
echo ">> install dir : $AGENT_DIR"

export DEBIAN_FRONTEND=noninteractive
echo ">> install dependencies..."
apt-get update -qq
apt-get install -y -qq python3 python3-urllib3 inotify-tools ca-certificates curl

mkdir -p "$AGENT_DIR" "$WATCH_DIR"

echo ">> fetch agent.py..."
AGENT_PY_URL="${PANEL_URL%/}/api/agent.py.php"
curl -fsSL "$AGENT_PY_URL" -o "$AGENT_DIR/agent.py"
chmod 0755 "$AGENT_DIR/agent.py"

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

AGENT_ID="$(printf '%s' "$REG_RESP"  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("agent_id",""))')"
API_KEY="$(printf '%s' "$REG_RESP"   | python3 -c 'import json,sys; print(json.load(sys.stdin).get("api_key",""))')"
REPORT_URL="$(printf '%s' "$REG_RESP"| python3 -c 'import json,sys; print(json.load(sys.stdin).get("report_url",""))')"

if [[ -z "$AGENT_ID" || -z "$API_KEY" ]]; then
  echo "Gagal register. Response:" >&2
  echo "$REG_RESP" >&2
  exit 1
fi

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

echo ">> systemd unit..."
cat > /etc/systemd/system/ehomee-agent.service <<EOF
[Unit]
Description=ehomee remote agent ($AGENT_NAME)
After=network.target

[Service]
Type=simple
EnvironmentFile=$AGENT_DIR/config.env
ExecStart=/usr/bin/python3 $AGENT_DIR/agent.py
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

sleep 2
systemctl status ehomee-agent --no-pager --lines=5 || true

cat <<EOF

=========================================
 ehomee agent - terpasang
=========================================
 Agent ID : $AGENT_ID
 Name     : $AGENT_NAME
 Panel    : $PANEL_URL
 Watch    : $WATCH_DIR
 Service  : systemctl status ehomee-agent
 Logs     : journalctl -u ehomee-agent -f

 Buka panel → tab "Agents" untuk verifikasi.
=========================================
EOF
