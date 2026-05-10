#!/usr/bin/env bash
# ehomee server panel — UPDATE script.
# Jalankan sebagai root di VPS panel:
#   cd /root/ehomee && git pull && sudo bash server-panel/update.sh
#
# Script ini:
#  1. sync file dari repo ke /opt/ehomee-panel
#  2. heal config.local.php (tambah key baru yang kurang)
#  3. fix permission
#  4. reload apache
#  5. self-test: panggil endpoint internal, lapor kalau ada yang gagal
#  6. generate & cetak one-liner install agent yang siap paste

set -euo pipefail

PANEL_DIR="${PANEL_DIR:-/opt/ehomee-panel}"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -ne 0 ]]; then
  echo "Harus dijalankan sebagai root (sudo bash $0)." >&2
  exit 1
fi

if [[ ! -d "$PANEL_DIR" ]]; then
  echo "ERROR: $PANEL_DIR tidak ada. Jalankan install.sh dulu." >&2
  exit 1
fi

CFG="$PANEL_DIR/includes/config.local.php"
echo ">> panel dir : $PANEL_DIR"
echo ">> source    : $SRC_DIR"
echo ">> config    : $CFG"

if [[ ! -f "$CFG" ]]; then
  echo "ERROR: $CFG tidak ada. Jalankan install.sh sekali lagi, bukan update.sh." >&2
  exit 1
fi

# ---- backup config ----
BACKUP="$CFG.bak.$(date +%s)"
cp -a "$CFG" "$BACKUP"
echo ">> backup    : $BACKUP"

# ---- sync file (exclude data & config) ----
echo ">> sync file ke $PANEL_DIR..."
rsync -a --delete \
  --exclude 'data/events.log' \
  --exclude 'data/agents.json' \
  --exclude 'data/agent-events/' \
  --exclude 'includes/config.local.php' \
  --exclude '__pycache__/' \
  "$SRC_DIR"/ "$PANEL_DIR"/

# ---- heal data dir ----
mkdir -p "$PANEL_DIR/data" "$PANEL_DIR/data/agent-events"
[[ -f "$PANEL_DIR/data/events.log" ]] || touch "$PANEL_DIR/data/events.log"
[[ -f "$PANEL_DIR/data/agents.json" ]] || echo '[]' > "$PANEL_DIR/data/agents.json"

# ---- heal config: tambah key yang kurang ----
echo ">> cek & heal config..."
php <<PHP
<?php
\$path = '$CFG';
\$cfg  = require \$path;
if (!is_array(\$cfg)) { fwrite(STDERR, "config bukan array\n"); exit(2); }

\$defaults = [
    'watch_dir'          => '/var/www/html',
    'events_log'         => '$PANEL_DIR/data/events.log',
    'agents_file'        => '$PANEL_DIR/data/agents.json',
    'max_edit_bytes'     => 2 * 1024 * 1024,
    'max_upload_bytes'   => 100 * 1024 * 1024,
    'telegram_bot_token' => '',
    'telegram_chat_id'   => '',
];
\$changed = false;
foreach (\$defaults as \$k => \$v) {
    if (!array_key_exists(\$k, \$cfg)) { \$cfg[\$k] = \$v; \$changed = true; echo "  + add \$k\n"; }
}
if (empty(\$cfg['enrollment_token'])) {
    \$cfg['enrollment_token'] = bin2hex(random_bytes(16));
    \$changed = true;
    echo "  + add enrollment_token (baru)\n";
}
if (empty(\$cfg['app_key'])) {
    \$cfg['app_key'] = bin2hex(random_bytes(32));
    \$changed = true;
    echo "  + add app_key\n";
}
if (\$changed) {
    \$php = "<?php\nreturn " . var_export(\$cfg, true) . ";\n";
    \$tmp = \$path . '.tmp';
    file_put_contents(\$tmp, \$php);
    chmod(\$tmp, 0600);
    rename(\$tmp, \$path);
    echo "  config updated\n";
} else {
    echo "  config OK\n";
}
PHP

# ---- permissions ----
echo ">> fix permission..."
chown -R www-data:www-data "$PANEL_DIR"
chmod 600 "$CFG"
find "$PANEL_DIR/data" -type d -exec chmod 775 {} \;
find "$PANEL_DIR/data" -type f -exec chmod 664 {} \;

# ---- clear PHP OPcache supaya install.sh.php baca template yang baru ----
echo ">> clear PHP OPcache..."
php -r 'function_exists("opcache_reset") && opcache_reset();' 2>/dev/null || true
# Apache mod_php pakai OPcache terpisah (in-process). Harus restart Apache, bukan reload.

# ---- apache ----
echo ">> FULL restart apache (clear in-process cache)..."
systemctl restart apache2
sleep 1

# ---- cari port apache untuk panel ----
PORT="$(awk '/^<VirtualHost/ && /:/ {gsub(/[<>]/,""); split($2,a,":"); print a[2]; exit}' \
  /etc/apache2/sites-enabled/ehomee-panel.conf 2>/dev/null)"
[[ -z "$PORT" ]] && PORT=8088
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
BASE="http://127.0.0.1:$PORT"
PUBLIC="http://${IP:-<ip>}:$PORT"

# ---- self-test ----
echo ""
echo "=== SELF TEST ==="

TOKEN="$(php -r "\$c = require '$CFG'; echo \$c['enrollment_token'] ?? '';")"
if [[ -z "$TOKEN" ]]; then
  echo "!! enrollment_token MASIH kosong setelah heal. Cek $CFG manual." >&2
  exit 2
fi

check() {
  local label="$1" url="$2" expect="$3"
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' "$url" || echo 000)"
  if [[ "$code" == "$expect" ]]; then
    printf "  OK   %-40s %s\n" "$label" "[$code]"
  else
    printf "  FAIL %-40s [got=%s want=%s]\n" "$label" "$code" "$expect"
    return 1
  fi
}

FAILS=0
check "login page"               "$BASE/login.php"                              200 || FAILS=$((FAILS+1))
check "install.sh.php no token"  "$BASE/api/install.sh.php?token=wrong"        401 || FAILS=$((FAILS+1))
check "install.sh.php valid"     "$BASE/api/install.sh.php?token=$TOKEN"       200 || FAILS=$((FAILS+1))
check "agent.py.php"             "$BASE/api/agent.py.php"                      200 || FAILS=$((FAILS+1))
check "register (no token)"      "$BASE/api/agent/register.php"                405 || FAILS=$((FAILS+1))
check "report (no auth)"         "$BASE/api/agent/report.php"                  405 || FAILS=$((FAILS+1))

# test isi install.sh.php: pastikan placeholder sudah ter-replace
CONTENT="$(curl -s "$BASE/api/install.sh.php?token=$TOKEN&name=selftest&watch=/tmp&method=auto")"
if echo "$CONTENT" | head -n5 | grep -q '__PANEL_URL__'; then
  echo "  FAIL install.sh.php masih mengandung placeholder __PANEL_URL__"
  FAILS=$((FAILS+1))
else
  echo "  OK   install.sh.php placeholder ter-replace"
fi

# VERIFIKASI FIX v2: pastikan kode baru benar-benar ter-serve (bukan cache)
if echo "$CONTENT" | grep -qE '^set -euo pipefail'; then
  echo "  FAIL installer masih pakai 'set -euo pipefail' (versi lama) — cache issue"
  echo "       coba manual: sudo systemctl restart apache2"
  FAILS=$((FAILS+1))
else
  echo "  OK   installer pakai 'set -eo pipefail' (fix v2 aktif)"
fi
if echo "$CONTENT" | grep -q 'getent passwd'; then
  echo "  OK   installer punya HOME fallback (fix v2 aktif)"
else
  echo "  FAIL installer TIDAK punya HOME fallback — cache issue"
  echo "       coba manual: sudo systemctl restart apache2"
  FAILS=$((FAILS+1))
fi
if echo "$CONTENT" | grep -q '_PH_PREFIX'; then
  echo "  OK   installer punya placeholder self-match guard (fix v2 aktif)"
else
  echo "  FAIL installer TIDAK punya placeholder guard — cache issue"
  FAILS=$((FAILS+1))
fi

echo ""
if [[ $FAILS -gt 0 ]]; then
  echo "  !! $FAILS check gagal. Baca error di atas." >&2
  echo "  tail log apache: tail -n 30 /var/log/apache2/ehomee-panel-error.log" >&2
  exit 3
fi

# ---- cetak one-liner siap pakai ----
cat <<EOF

=========================================
 PANEL UPDATE SUKSES (semua check LULUS)
=========================================
 URL panel        : $PUBLIC
 Config           : $CFG
 Backup sebelumnya: $BACKUP
 Enrollment token : $TOKEN

 One-liner siap paste di server target (COPY PERSIS, pakai tanda kutip):

  MODE ROOT (default):
    curl -fsSL '$PUBLIC/api/install.sh.php?token=$TOKEN&name=srv-b&watch=auto&method=auto' | sudo bash

  MODE USER BIASA (tanpa sudo):
    curl -fsSL '$PUBLIC/api/install.sh.php?token=$TOKEN&name=srv-b&watch=auto&method=auto' | bash

 Ganti metode kalau perlu: &method=systemd-system | systemd-user | cron | nohup

 Langkah berikutnya di server target:
  1. Paste salah satu one-liner di atas PERSIS (dengan tanda kutip)
  2. Installer auto-detect watch_dir (webroot/home/public_html)
  3. Installer auto-pilih metode (systemd/cron/nohup)
  4. Butuh MINIMAL: python3 + curl (inotify-tools opsional)
  5. Agent muncul di panel tab Agents dalam ~30 detik

 Cek log agent di server target:
  systemctl status ehomee-agent               # mode systemd
  systemctl --user status ehomee-agent        # mode systemd-user
  tail -f /opt/ehomee-agent/agent.log         # mode cron/nohup (root)
  tail -f ~/.local/share/ehomee-agent/agent.log  # mode cron/nohup (user)
=========================================
EOF
