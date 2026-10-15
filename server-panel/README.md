# ehomee server panel

Panel monitoring ringan untuk VPS: file manager, editor, upload, plus watcher
yang mendeteksi setiap perubahan file secara real-time (via `inotifywait`) dan
mengirim notifikasi ke Telegram.

Stack: **Apache + PHP** (tanpa framework) + **bash watcher** (systemd).

## Fitur

- Login (password bcrypt, session + CSRF)
- Tab **Files**: list folder, navigasi breadcrumb, upload multi-file dengan
  progress, edit file teks inline, rename, delete, download, mkdir
- Tab **Events**: feed real-time perubahan file (create/modify/delete/move),
  auto-refresh
- Tab **System**: hostname, OS, uptime, load, memory, disk, top 5 proses CPU
- Notifikasi Telegram opsional saat file berubah
- Path traversal protection, proteksi direktori `includes/`, `watcher/`, `data/`

## Install di VPS (Ubuntu/Debian)

```bash
# di VPS Anda
git clone https://github.com/whomeee459-arch/ehomee.git
cd ehomee/server-panel

# jalankan installer (variabel di bawah opsional, bisa di-override)
sudo WATCH_DIR=/var/www/html \
     PORT=8088 \
     ADMIN_USER=admin \
     ADMIN_PASS='ganti-password-kuat' \
     TG_TOKEN='1234:AAA...'  \
     TG_CHAT='123456789'     \
     bash install.sh
```

Selesai. Installer akan:

1. `apt install apache2 php libapache2-mod-php inotify-tools ...`
2. Copy ke `/opt/ehomee-panel`
3. Buat Apache vhost di port `PORT`
4. Buat systemd unit `ehomee-watcher` dan mengaktifkannya
5. Mencetak URL + kredensial

Panel: `http://<server-ip>:<PORT>`

## Konfigurasi

Semua setting ada di `/opt/ehomee-panel/includes/config.local.php`:

| key                   | keterangan                                              |
|-----------------------|---------------------------------------------------------|
| `watch_dir`           | direktori yang dikelola & dipantau watcher              |
| `admin_user`          | username login                                          |
| `admin_pass_hash`     | bcrypt hash password                                    |
| `events_log`          | path log event perubahan file                           |
| `max_edit_bytes`      | batas ukuran file untuk editor inline (default 2 MB)    |
| `max_upload_bytes`    | batas ukuran upload per file (default 100 MB)           |
| `telegram_bot_token`  | opsional, untuk notifikasi                              |
| `telegram_chat_id`    | opsional                                                |

Setelah mengubah, restart watcher bila perlu:

```bash
sudo systemctl restart ehomee-watcher
```

## Ganti password

```bash
php -r "echo password_hash('passbaru', PASSWORD_BCRYPT) . PHP_EOL;"
# tempel outputnya ke admin_pass_hash di config.local.php
```

## Struktur folder

```
server-panel/
├── install.sh                    # installer
├── public/                       # DocumentRoot Apache
│   ├── index.php                 # dashboard
│   ├── login.php / logout.php
│   ├── .htaccess
│   ├── assets/{app.js,style.css}
│   └── api/*.php                 # endpoint JSON
├── includes/
│   ├── config.php                # loader
│   ├── config.local.php          # dibuat oleh installer (tidak di-commit)
│   ├── auth.php                  # session starter
│   └── helpers.php               # cfg(), safe_path(), csrf, dsb.
├── watcher/
│   ├── watch.sh                  # daemon inotifywait
│   └── ehomee-watcher.service    # systemd unit
└── data/events.log               # log event (generated)
```

## Debug

```bash
# log Apache
sudo tail -f /var/log/apache2/ehomee-panel-error.log

# status watcher
systemctl status ehomee-watcher
journalctl -u ehomee-watcher -f

# tail events mentah
tail -f /opt/ehomee-panel/data/events.log
```

## Catatan keamanan — harap dibaca

Panel ini memberi akses **baca-tulis** ke `watch_dir` bagi siapa pun yang
berhasil login. Sangat disarankan:

1. Pakai password kuat (minimal 16 karakter acak)
2. Taruh di belakang **HTTPS** (reverse proxy Caddy/Nginx + Let's Encrypt)
3. Batasi akses ke IP Anda — lihat `public/.htaccess`, ada contoh `Require ip`
   yang bisa di-uncomment
4. Buka port hanya di firewall untuk IP yang Anda percaya:
   ```bash
   sudo ufw allow from 1.2.3.4 to any port 8088 proto tcp
   ```
5. Jangan jalankan Apache sebagai root. `www-data` sudah default
6. Pertimbangkan MFA di reverse proxy (misal `oauth2-proxy` atau basic auth
   tambahan di Caddy)

## Uninstall

```bash
sudo systemctl disable --now ehomee-watcher
sudo rm /etc/systemd/system/ehomee-watcher.service
sudo a2dissite ehomee-panel && sudo systemctl reload apache2
sudo rm /etc/apache2/sites-available/ehomee-panel.conf
sudo rm -rf /opt/ehomee-panel
```
