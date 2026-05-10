/* ehomee panel — vanilla JS */
(function () {
  const CSRF = document.querySelector('meta[name=csrf]').content;
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));

  let currentPath = '';
  let eventsTimer = null;

  // ---------- utils ----------
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g,
    c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  function fmtBytes(n) {
    if (n == null) return '-';
    const u = ['B', 'KB', 'MB', 'GB', 'TB'];
    let i = 0; while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
    return (i === 0 ? n : n.toFixed(2)) + ' ' + u[i];
  }
  function fmtTime(iso) {
    const d = new Date(iso);
    if (isNaN(d)) return iso || '-';
    return d.toLocaleString();
  }
  function fmtUptime(s) {
    const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600),
          m = Math.floor((s % 3600) / 60);
    return `${d}h ${h}j ${m}m`;
  }

  async function api(url, opts = {}) {
    const res = await fetch(url, opts);
    const j = await res.json().catch(() => ({}));
    if (!res.ok || j.ok === false) throw new Error(j.error || ('HTTP ' + res.status));
    return j;
  }
  function form(obj) {
    const f = new FormData();
    f.append('csrf', CSRF);
    for (const k in obj) {
      const v = obj[k];
      if (Array.isArray(v)) v.forEach(x => f.append(k + '[]', x));
      else f.append(k, v);
    }
    return f;
  }

  // ---------- tab switch ----------
  $$('.tab').forEach(btn => btn.addEventListener('click', () => {
    $$('.tab').forEach(b => b.classList.remove('active'));
    $$('.view').forEach(v => v.classList.remove('active'));
    btn.classList.add('active');
    $('#view-' + btn.dataset.tab).classList.add('active');
    if (btn.dataset.tab === 'events') startEvents();
    else stopEvents();
    if (btn.dataset.tab === 'system') loadSystem();
  }));

  // ---------- files ----------
  async function loadDir(path = '') {
    currentPath = path;
    try {
      const j = await api('api/files.php?path=' + encodeURIComponent(path));
      renderCrumbs(j.path);
      renderList(j.items, j.path);
    } catch (e) {
      alert('Gagal memuat folder: ' + e.message);
    }
  }

  function renderCrumbs(path) {
    const parts = (path || '').split('/').filter(Boolean);
    const el = $('#breadcrumb');
    el.innerHTML = '';
    const addCrumb = (label, target) => {
      const a = document.createElement('a');
      a.textContent = label;
      a.href = '#';
      a.onclick = (e) => { e.preventDefault(); loadDir(target); };
      el.appendChild(a);
    };
    addCrumb('/', '');
    let acc = '';
    parts.forEach((p, i) => {
      acc = acc ? acc + '/' + p : p;
      el.append(' / ');
      addCrumb(p, acc);
    });
  }

  function renderList(items, path) {
    const tb = $('#file-list');
    tb.innerHTML = '';
    if (path) {
      const parent = path.split('/').slice(0, -1).join('/');
      tb.appendChild(row({
        name: '..', is_dir: true, size: null, mtime: '', path: parent, _up: true
      }));
    }
    items.forEach(it => tb.appendChild(row(it)));
  }

  function row(it) {
    const tr = document.createElement('tr');
    const icon = it.is_dir ? '📁' : '📄';
    const nameCell = document.createElement('td');
    const nameLink = document.createElement('a');
    nameLink.href = '#';
    nameLink.textContent = icon + ' ' + it.name;
    nameLink.onclick = (e) => {
      e.preventDefault();
      if (it.is_dir) loadDir(it._up ? it.path : it.path);
      else openEditor(it);
    };
    nameCell.appendChild(nameLink);

    tr.appendChild(nameCell);
    tr.appendChild(td(it.is_dir ? '—' : fmtBytes(it.size)));
    tr.appendChild(td(it.mtime ? fmtTime(it.mtime) : ''));

    const actions = document.createElement('td');
    actions.className = 'acts';
    if (!it._up) {
      if (!it.is_dir) {
        actions.appendChild(btn('Edit', () => openEditor(it)));
        const a = document.createElement('a');
        a.className = 'btn small';
        a.textContent = 'Download';
        a.href = 'api/download.php?path=' + encodeURIComponent(it.path);
        actions.appendChild(a);
      }
      actions.appendChild(btn('Rename', () => doRename(it)));
      actions.appendChild(btn('Delete', () => doDelete(it), 'danger'));
    }
    tr.appendChild(actions);
    return tr;
  }
  function td(t) { const x = document.createElement('td'); x.textContent = t; return x; }
  function btn(label, fn, cls = '') {
    const b = document.createElement('button');
    b.className = 'btn small ' + cls;
    b.textContent = label; b.onclick = fn; return b;
  }

  async function doDelete(it) {
    if (!confirm('Hapus "' + it.name + '" ?')) return;
    try { await api('api/delete.php', { method: 'POST', body: form({ path: it.path }) }); loadDir(currentPath); }
    catch (e) { alert('Gagal hapus: ' + e.message); }
  }
  async function doRename(it) {
    const n = prompt('Nama baru:', it.name);
    if (!n || n === it.name) return;
    try { await api('api/rename.php', { method: 'POST', body: form({ path: it.path, name: n }) }); loadDir(currentPath); }
    catch (e) { alert('Gagal rename: ' + e.message); }
  }

  // mkdir
  $('#btn-mkdir').onclick = async () => {
    const n = prompt('Nama folder baru:');
    if (!n) return;
    try { await api('api/mkdir.php', { method: 'POST', body: form({ path: currentPath, name: n }) }); loadDir(currentPath); }
    catch (e) { alert('Gagal mkdir: ' + e.message); }
  };
  $('#btn-refresh').onclick = () => loadDir(currentPath);

  // upload
  $('#upload-input').addEventListener('change', async (e) => {
    const files = e.target.files;
    if (!files || !files.length) return;
    const fd = new FormData();
    fd.append('csrf', CSRF);
    fd.append('path', currentPath);
    for (const f of files) fd.append('files[]', f);

    const prog = $('#upload-progress');
    prog.classList.remove('hidden');
    const bar = prog.firstElementChild;
    bar.style.width = '0%';
    try {
      await new Promise((resolve, reject) => {
        const xhr = new XMLHttpRequest();
        xhr.open('POST', 'api/upload.php');
        xhr.upload.onprogress = (ev) => {
          if (ev.lengthComputable) bar.style.width = ((ev.loaded / ev.total) * 100).toFixed(1) + '%';
        };
        xhr.onload = () => {
          try { const j = JSON.parse(xhr.responseText); if (xhr.status < 400 && j.ok) resolve(j); else reject(new Error(j.error || 'HTTP ' + xhr.status)); }
          catch (err) { reject(err); }
        };
        xhr.onerror = () => reject(new Error('network'));
        xhr.send(fd);
      });
      loadDir(currentPath);
    } catch (err) { alert('Upload gagal: ' + err.message); }
    finally {
      setTimeout(() => { prog.classList.add('hidden'); bar.style.width = '0%'; }, 600);
      e.target.value = '';
    }
  });

  // editor
  const modal = $('#modal-edit');
  const area = $('#edit-area');
  let editingPath = null;
  async function openEditor(it) {
    try {
      const j = await api('api/edit.php?path=' + encodeURIComponent(it.path));
      editingPath = it.path;
      $('#edit-name').textContent = it.name;
      $('#edit-path').textContent = ' · /' + j.path;
      area.value = j.content;
      modal.classList.remove('hidden');
    } catch (e) { alert('Gagal buka: ' + e.message); }
  }
  $('#edit-close').onclick = () => modal.classList.add('hidden');
  $('#edit-save').onclick = async () => {
    try {
      await api('api/edit.php', { method: 'POST', body: form({ path: editingPath, content: area.value }) });
      modal.classList.add('hidden');
      loadDir(currentPath);
    } catch (e) { alert('Gagal simpan: ' + e.message); }
  };

  // ---------- events ----------
  async function loadEvents() {
    try {
      const j = await api('api/events.php?limit=200');
      const box = $('#events-list');
      box.innerHTML = '';
      if (!j.events.length) { box.innerHTML = '<div class="muted pad">belum ada event</div>'; return; }
      j.events.forEach(ev => {
        const div = document.createElement('div');
        div.className = 'ev ev-' + classifyEvent(ev.event);
        div.innerHTML = `
          <span class="ts">${esc(fmtTime(ev.ts))}</span>
          <span class="tag">${esc(ev.event)}</span>
          <span class="path">${esc(ev.path)}</span>
        `;
        box.appendChild(div);
      });
    } catch (e) { /* silent */ }
  }
  function classifyEvent(e) {
    if (/DELETE/.test(e)) return 'del';
    if (/CREATE/.test(e)) return 'new';
    if (/MODIFY/.test(e)) return 'mod';
    if (/MOVE/.test(e)) return 'mov';
    return 'other';
  }
  function startEvents() { loadEvents(); stopEvents(); if ($('#events-auto').checked) eventsTimer = setInterval(loadEvents, 3000); }
  function stopEvents() { if (eventsTimer) clearInterval(eventsTimer); eventsTimer = null; }
  $('#events-auto').onchange = startEvents;
  $('#btn-events-refresh').onclick = loadEvents;

  // ---------- system ----------
  async function loadSystem() {
    try {
      const j = await api('api/system.php');
      const pct = (u, t) => t ? ((u / t) * 100).toFixed(1) + '%' : '0%';
      const mem = j.memory, disk = j.disk;
      const html = `
        <div class="grid2">
          <div class="card">
            <div class="k">Host</div><div class="v">${esc(j.hostname)}</div>
            <div class="k">OS</div><div class="v small">${esc(j.os)}</div>
            <div class="k">PHP</div><div class="v">${esc(j.php)}</div>
            <div class="k">CPU</div><div class="v small">${esc(j.cpu.model)} · ${j.cpu.cores} core</div>
            <div class="k">Uptime</div><div class="v">${fmtUptime(j.uptime_sec)}</div>
            <div class="k">Load</div><div class="v">${j.loadavg.map(n => n.toFixed(2)).join(' / ')}</div>
          </div>
          <div class="card">
            <div class="k">Memory</div>
            <div class="v">
              ${fmtBytes(mem.used)} / ${fmtBytes(mem.total)} (${pct(mem.used, mem.total)})
              <div class="bar"><div style="width:${pct(mem.used, mem.total)}"></div></div>
            </div>
            <div class="k">Disk (${esc(disk.path)})</div>
            <div class="v">
              ${fmtBytes(disk.used)} / ${fmtBytes(disk.total)} (${pct(disk.used, disk.total)})
              <div class="bar"><div style="width:${pct(disk.used, disk.total)}"></div></div>
            </div>
          </div>
        </div>
        <h3>Top process</h3>
        <pre class="top">${esc(j.top)}</pre>
      `;
      $('#system-info').innerHTML = html;
    } catch (e) {
      $('#system-info').innerHTML = '<div class="alert err">' + esc(e.message) + '</div>';
    }
  }
  $('#btn-sys-refresh').onclick = loadSystem;

  // ---------- init ----------
  loadDir('');
})();
