<?php
require_once __DIR__ . '/../includes/auth.php';
require_login();
$c = cfg();
$csrf = csrf_token();
?>
<!doctype html>
<html lang="id">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>ehomee panel</title>
  <link rel="stylesheet" href="assets/style.css">
  <meta name="csrf" content="<?= htmlspecialchars($csrf) ?>">
</head>
<body>
<header class="topbar">
  <div class="topbar-inner">
    <h1>ehomee <span class="muted">panel</span></h1>
    <nav class="tabs">
      <button class="tab active" data-tab="files">Files</button>
      <button class="tab" data-tab="events">Events</button>
      <button class="tab" data-tab="system">System</button>
      <button class="tab" data-tab="agents">Agents</button>
    </nav>
    <div class="meta">
      <span class="muted">user:</span> <b><?= htmlspecialchars($_SESSION['uid']) ?></b>
      <a class="btn ghost" href="logout.php">Logout</a>
    </div>
  </div>
</header>

<main>
  <!-- FILES -->
  <section class="view active" id="view-files">
    <div class="toolbar">
      <div id="breadcrumb" class="crumbs">/</div>
      <div class="actions">
        <label class="btn">
          Upload
          <input type="file" id="upload-input" multiple hidden>
        </label>
        <button class="btn" id="btn-mkdir">New folder</button>
        <button class="btn" id="btn-refresh">Refresh</button>
      </div>
    </div>
    <div id="upload-progress" class="progress hidden"><div></div></div>
    <table class="files">
      <thead>
        <tr><th>Nama</th><th>Ukuran</th><th>Diubah</th><th>Aksi</th></tr>
      </thead>
      <tbody id="file-list"></tbody>
    </table>
  </section>

  <!-- EVENTS -->
  <section class="view" id="view-events">
    <div class="toolbar">
      <div><b>Event perubahan file</b> <span class="muted">(dari watcher systemd)</span></div>
      <div class="actions">
        <label class="switch">
          <input type="checkbox" id="events-auto" checked> auto-refresh
        </label>
        <button class="btn" id="btn-events-refresh">Refresh</button>
      </div>
    </div>
    <div id="events-list" class="events"></div>
  </section>

  <!-- SYSTEM -->
  <section class="view" id="view-system">
    <div class="toolbar">
      <div><b>Informasi sistem</b></div>
      <div class="actions">
        <button class="btn" id="btn-sys-refresh">Refresh</button>
      </div>
    </div>
    <div id="system-info" class="system"></div>
  </section>

  <!-- AGENTS -->
  <section class="view" id="view-agents">
    <div class="toolbar">
      <div>
        <b>Remote agents</b>
        <span class="muted">(server lain yang terhubung)</span>
      </div>
      <div class="actions">
        <button class="btn primary" id="btn-add-agent">+ Add server</button>
        <button class="btn" id="btn-rotate-token" title="Rotate enrollment token">Rotate token</button>
        <button class="btn" id="btn-agents-refresh">Refresh</button>
      </div>
    </div>
    <div id="agent-list" class="agent-list"></div>
  </section>
</main>

<!-- Modal: add agent (one-liner) -->
<div class="modal hidden" id="modal-add-agent">
  <div class="modal-box modal-small">
    <header>
      <b>Install agent di server baru</b>
      <div>
        <button class="btn ghost" id="add-agent-close">Tutup</button>
      </div>
    </header>
    <div class="pad">
      <div class="form-row">
        <label>Nama server (opsional)
          <input id="add-agent-name" placeholder="srv-b, backend-1, db-prod...">
        </label>
        <label>Watch dir (folder yang mau dipantau)
          <select id="add-agent-watch-preset">
            <option value="auto">auto-detect (rekomendasi) — webroot/home/public</option>
            <option value="/var/www/html">/var/www/html (Apache default)</option>
            <option value="/usr/share/nginx/html">/usr/share/nginx/html (Nginx)</option>
            <option value="/srv/http">/srv/http (Arch)</option>
            <option value="$HOME/public_html">$HOME/public_html (cPanel)</option>
            <option value="$HOME/www">$HOME/www</option>
            <option value="$HOME">$HOME (seluruh home user)</option>
            <option value="__custom__">— custom —</option>
          </select>
          <input id="add-agent-watch" class="hidden" placeholder="/path/custom">
        </label>
        <label class="switch" style="flex-direction:row; align-items:center;">
          <input type="checkbox" id="add-agent-userm"> jalankan sebagai user biasa (tanpa sudo)
        </label>
        <label>Metode start
          <select id="add-agent-method">
            <option value="auto">auto (rekomendasi) — deteksi systemd / cron / nohup</option>
            <option value="systemd-system">systemd-system (butuh root)</option>
            <option value="systemd-user">systemd-user (user biasa, butuh systemd)</option>
            <option value="cron">cron @reboot (fallback, auto-supervise tiap menit)</option>
            <option value="nohup">nohup (fallback terakhir, tidak auto-restart reboot)</option>
          </select>
        </label>
      </div>
      <div class="form-row">
        <button class="btn primary" id="add-agent-gen">Generate one-liner</button>
      </div>
      <div id="add-agent-result" class="hidden">
        <p class="muted small">Jalankan sebagai root di server target. Agent akan terdaftar otomatis dalam beberapa detik.</p>
        <pre class="cmd" id="add-agent-cmd"></pre>
        <button class="btn small" id="add-agent-copy">Salin</button>
      </div>
    </div>
  </div>
</div>

<!-- Modal: detail agent -->
<div class="modal hidden" id="modal-agent">
  <div class="modal-box">
    <header>
      <div>
        <b id="agent-title">-</b>
        <span class="muted small" id="agent-sub"></span>
      </div>
      <div>
        <button class="btn ghost" id="agent-close">Tutup</button>
      </div>
    </header>
    <div id="agent-detail" class="pad"></div>
  </div>
</div>

<!-- Modal editor -->
<div class="modal hidden" id="modal-edit">
  <div class="modal-box">
    <header>
      <div>
        <b id="edit-name">-</b>
        <span class="muted" id="edit-path"></span>
      </div>
      <div>
        <button class="btn primary" id="edit-save">Simpan</button>
        <button class="btn ghost" id="edit-close">Tutup</button>
      </div>
    </header>
    <textarea id="edit-area" spellcheck="false"></textarea>
  </div>
</div>

<script src="assets/app.js"></script>
</body>
</html>
