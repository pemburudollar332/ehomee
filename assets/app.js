/* ehomee dashboard — membaca data/status.json dan data/history.json */
(function () {
  const STATUS_URL = "data/status.json";
  const HISTORY_URL = "data/history.json";

  const $ = (sel) => document.querySelector(sel);

  function fmtTime(iso) {
    if (!iso) return "-";
    const d = new Date(iso);
    if (isNaN(d)) return iso;
    return d.toLocaleString();
  }

  function renderSummary(s) {
    $("#s-total").textContent = s.total ?? 0;
    $("#s-up").textContent = s.up ?? 0;
    $("#s-down").textContent = s.down ?? 0;
    $("#s-degraded").textContent = s.degraded ?? 0;
  }

  function siteCard(c) {
    const el = document.createElement("div");
    el.className = "card site";
    const ssl =
      c.ssl_days_left == null
        ? "-"
        : c.ssl_days_left + " hari";
    el.innerHTML = `
      <div class="site-head">
        <div class="name">${escapeHtml(c.label || c.url)}</div>
        <span class="badge ${c.status}">${c.status}</span>
      </div>
      <div class="url">${escapeHtml(c.url)}</div>
      <div class="row"><span>HTTP</span><b>${escapeHtml(c.http_code)}</b></div>
      <div class="row"><span>Response</span><b>${c.response_ms} ms</b></div>
      <div class="row"><span>Ukuran</span><b>${formatBytes(c.size_bytes)}</b></div>
      <div class="row"><span>SSL tersisa</span><b>${escapeHtml(String(ssl))}</b></div>
      ${
        c.error
          ? `<div class="row" style="color:var(--down)"><span>Error</span><b>${escapeHtml(
              c.error
            )}</b></div>`
          : ""
      }
      <div class="row"><span>Dicek</span><b>${fmtTime(c.checked_at)}</b></div>
    `;
    return el;
  }

  function formatBytes(n) {
    if (!n && n !== 0) return "-";
    if (n < 1024) return n + " B";
    if (n < 1024 * 1024) return (n / 1024).toFixed(1) + " KB";
    return (n / 1048576).toFixed(2) + " MB";
  }

  function escapeHtml(s) {
    return String(s ?? "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  async function loadStatus() {
    try {
      const res = await fetch(STATUS_URL + "?_=" + Date.now());
      if (!res.ok) throw new Error("HTTP " + res.status);
      const data = await res.json();

      $("#last-updated").textContent = "diperbarui: " + fmtTime(data.generated_at);
      renderSummary(data.summary || {});

      const grid = $("#checks");
      grid.innerHTML = "";
      (data.checks || []).forEach((c) => grid.appendChild(siteCard(c)));
    } catch (e) {
      $("#last-updated").textContent = "gagal memuat data (" + e.message + ")";
    }
  }

  async function loadHistory() {
    try {
      const res = await fetch(HISTORY_URL + "?_=" + Date.now());
      if (!res.ok) return;
      const hist = await res.json();
      const box = $("#history");
      box.innerHTML = "";
      hist
        .slice(-30)
        .reverse()
        .forEach((h) => {
          const row = document.createElement("div");
          row.className = "history-row";
          const bars = (h.checks || [])
            .map(
              (c) =>
                `<span class="${c.status}" title="${escapeHtml(c.url)} — ${
                  c.status
                } (${c.http_code})"></span>`
            )
            .join("");
          row.innerHTML = `
            <div class="ts">${fmtTime(h.generated_at)}</div>
            <div class="bars">${bars}</div>
          `;
          box.appendChild(row);
        });
    } catch (_) {
      /* history optional */
    }
  }

  function refresh() {
    loadStatus();
    loadHistory();
  }

  $("#refresh").addEventListener("click", refresh);
  refresh();
  // auto refresh tiap 60 detik
  setInterval(refresh, 60_000);
})();
