# ehomee — Website Monitor (curl-based)

Dashboard statis untuk memonitor uptime beberapa website. Pengecekan dilakukan oleh
script bash sederhana yang memanggil `curl`, lalu hasilnya disimpan sebagai JSON
dan ditampilkan oleh halaman HTML.

## Struktur

```
ehomee/
├── index.html            # dashboard
├── assets/
│   ├── app.js            # fetch & render status
│   └── style.css
├── scripts/
│   └── check.sh          # runner curl -> data/status.json
├── data/
│   ├── status.json       # hasil cek terakhir (digenerate)
│   └── history.json      # riwayat ringkas (digenerate)
├── sites.txt             # daftar URL yang dimonitor
└── .github/workflows/monitor.yml  # cron tiap 15 menit + deploy Pages
```

## Menjalankan secara lokal

```bash
# 1. cek situs
bash scripts/check.sh

# 2. buka dashboard (butuh HTTP server karena fetch ke file JSON)
python3 -m http.server 8080
# lalu buka http://localhost:8080
```

Output utama ada di `data/status.json`:

```json
{
  "generated_at": "2025-05-10T12:34:56Z",
  "summary": { "total": 6, "up": 5, "down": 1, "degraded": 0 },
  "checks": [
    {
      "url": "https://github.com",
      "label": "GitHub",
      "status": "up",
      "http_code": "200",
      "response_ms": 312,
      "size_bytes": 253123,
      "ssl_days_left": 76,
      "error": "",
      "checked_at": "2025-05-10T12:34:56Z"
    }
  ]
}
```

## Menambah/mengubah situs

Edit `sites.txt`. Satu URL per baris, label opsional:

```
https://example.com        Contoh Situs
https://api.example.com    Contoh API
# baris dengan '#' diabaikan
```

## Konfigurasi (env)

Bisa di-override saat menjalankan `scripts/check.sh`:

| Variabel      | Default              | Keterangan                          |
|---------------|----------------------|-------------------------------------|
| `TIMEOUT`     | `10`                 | timeout curl per request (detik)    |
| `USER_AGENT`  | `ehomee-monitor/1.0` | header User-Agent                   |
| `MAX_HISTORY` | `288`                | jumlah snapshot di `history.json`   |

Contoh:
```bash
TIMEOUT=5 MAX_HISTORY=1000 bash scripts/check.sh
```

## Logika status

| Kondisi                                | Status     |
|----------------------------------------|------------|
| HTTP 2xx atau 3xx                       | `up`       |
| HTTP 4xx / 5xx                          | `degraded` |
| Tidak ada response / timeout (code 000) | `down`     |

Selain itu, untuk URL HTTPS, script mengambil sisa hari sertifikat SSL via
`openssl s_client`.

## Deploy otomatis (GitHub Pages)

Workflow `.github/workflows/monitor.yml`:

1. Cron setiap 15 menit menjalankan `scripts/check.sh`
2. Commit `data/status.json` dan `data/history.json` ke `main`
3. Deploy seluruh repo ke GitHub Pages

Aktifkan Pages: **Settings → Pages → Source: GitHub Actions**.

Dashboard akan tersedia di `https://<user>.github.io/<repo>/`.

## Cron lokal (alternatif)

```cron
*/15 * * * *  cd /path/to/ehomee && /bin/bash scripts/check.sh >> monitor.log 2>&1
```

## Dependensi

- `bash`, `curl`, `openssl`, `python3` (hanya untuk escape JSON & ring-buffer history)
- Semuanya sudah tersedia di runner `ubuntu-latest`
