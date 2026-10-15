#!/usr/bin/env bash
# ehomee server panel - installer untuk Ubuntu/Debian VPS
# Jalankan sebagai root:  sudo bash install.sh

set -euo pipefail

# ---- config (bisa di-override lewat env) ----
PANEL_DIR="${PANEL_DIR:-/opt/ehomee-panel}"
WATCH_DIR="${WATCH_DIR:-/var/www/html}"
PORT="${PORT:-8088}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-$(openssl rand -base64 12)}"
TG_TOKEN="${TG_TOKEN:-}"
TG_CHAT="${TG_CHAT:-}"

if [[ $EUID -ne 0 ]]; then
  echo "Harus dijalankan sebagai root (pakai sudo)." >&2
  exit 1
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo ">> source    : $SRC_DIR"
echo ">> panel dir : $PANEL_DIR"
echo ">> watch dir : $WATCH_DIR"
echo ">> port      : $PORT"

mkdir -p "$WATCH_DIR"

echo ">> install paket..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  apache2 php libapache2-mod-php php-mbstring php-json \
  inotify-tools rsync curl openssl

echo ">> copy file ke $PANEL_DIR..."
mkdir -p "$PANEL_DIR"
rsync -a --delete \
  --exclude 'data/events.log' \
  --exclude 'includes/config.local.php' \
  "$SRC_DIR"/ "$PANEL_DIR"/
mkdir -p "$PANEL_DIR/data"
touch "$PANEL_DIR/data/events.log"

echo ">> generate config.local.php..."
PASS_HASH="$(php -r "echo password_hash(getenv('P'), PASSWORD_BCRYPT);" P="$ADMIN_PASS")"
APP_KEY="$(openssl rand -hex 32)"
cat > "$PANEL_DIR/includes/config.local.php" <<PHP
<?php
return [
  'watch_dir'           => '$WATCH_DIR',
  'admin_user'          => '$ADMIN_USER',
  'admin_pass_hash'     => '$PASS_HASH',
  'app_key'             => '$APP_KEY',
  'events_log'          => '$PANEL_DIR/data/events.log',
  'max_edit_bytes'      => 2 * 1024 * 1024,   // 2 MB
  'max_upload_bytes'    => 100 * 1024 * 1024, // 100 MB
  'telegram_bot_token'  => '$TG_TOKEN',
  'telegram_chat_id'    => '$TG_CHAT',
];
PHP

echo ">> permission..."
chown -R www-data:www-data "$PANEL_DIR"
chmod 600 "$PANEL_DIR/includes/config.local.php"
# www-data harus bisa baca/tulis watch_dir untuk file ops
if [[ "$WATCH_DIR" == /var/www/* ]]; then
  chown -R www-data:www-data "$WATCH_DIR" || true
fi

echo ">> konfigurasi Apache (port $PORT)..."
# tambahkan Listen jika belum ada
if ! grep -qE "^\s*Listen\s+$PORT\b" /etc/apache2/ports.conf; then
  echo "Listen $PORT" >> /etc/apache2/ports.conf
fi

cat > /etc/apache2/sites-available/ehomee-panel.conf <<APACHE
<VirtualHost *:$PORT>
    ServerAdmin webmaster@localhost
    DocumentRoot $PANEL_DIR/public

    <Directory $PANEL_DIR/public>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    # proteksi folder sensitif
    <Directory $PANEL_DIR/includes>
        Require all denied
    </Directory>
    <Directory $PANEL_DIR/watcher>
        Require all denied
    </Directory>
    <Directory $PANEL_DIR/data>
        Require all denied
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/ehomee-panel-error.log
    CustomLog \${APACHE_LOG_DIR}/ehomee-panel-access.log combined
</VirtualHost>
APACHE

a2enmod rewrite headers >/dev/null
a2ensite ehomee-panel >/dev/null
# upload limit: sesuaikan php.ini runtime via .htaccess sudah, tapi beberapa SAPI butuh override ini
PHP_INI="$(php -r 'echo php_ini_loaded_file();')"
if [[ -n "$PHP_INI" && -f "$PHP_INI" ]]; then
  sed -i 's/^\s*upload_max_filesize.*/upload_max_filesize = 100M/' "$PHP_INI" || true
  sed -i 's/^\s*post_max_size.*/post_max_size = 110M/' "$PHP_INI" || true
fi
systemctl reload apache2

echo ">> install systemd unit untuk watcher..."
cp "$PANEL_DIR/watcher/ehomee-watcher.service" /etc/systemd/system/ehomee-watcher.service
sed -i "s|{{PANEL_DIR}}|$PANEL_DIR|g" /etc/systemd/system/ehomee-watcher.service
systemctl daemon-reload
systemctl enable --now ehomee-watcher

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
cat <<EOF

========================================
 ehomee server panel - selesai terpasang
========================================
 URL   : http://${IP:-<server-ip>}:$PORT
 User  : $ADMIN_USER
 Pass  : $ADMIN_PASS

 Watch dir : $WATCH_DIR
 Panel dir : $PANEL_DIR
 Events    : $PANEL_DIR/data/events.log
 Service   : systemctl status ehomee-watcher

Catatan:
  - Ganti password: edit password_hash di $PANEL_DIR/includes/config.local.php
  - Telegram: set TG_TOKEN & TG_CHAT sebelum menjalankan installer,
              atau edit config.local.php lalu: systemctl restart ehomee-watcher
  - Buka port di firewall: ufw allow $PORT/tcp
  - Sangat disarankan letakkan di belakang HTTPS/reverse proxy (Caddy/Nginx)
    dan batasi akses ke IP Anda di .htaccess.
========================================
EOF
