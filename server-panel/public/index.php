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
  <div class="bar">
    <h1>ehomee <span class="muted">panel</span></h1>
    <nav class="tabs">
      <button class="tab active" data-tab="files">Files</button>
      <button class="tab" data-tab="events">Events</button>
      <button class="tab" data-tab="system">System</button>
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
</main>

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
