#!/usr/bin/env python3
"""
ehomee-agent
Menjalankan:
  - collector: mengumpulkan metrik sistem (uptime, load, mem, disk) tiap INTERVAL detik
  - watcher: memantau WATCH_DIR. Mode watcher dipilih otomatis:
      1. inotify  : pakai `inotifywait` kalau tersedia (real-time, CPU rendah)
      2. polling  : fallback murni Python stdlib (scan mtime tiap POLL_INTERVAL detik)

Lalu push ke REPORT_URL (POST JSON) dengan header:
  X-Agent-Id: <AGENT_ID>
  Authorization: Bearer <API_KEY>

Dikonfigurasi via environment (disuntik oleh wrapper agent-start.sh).
Dependensi wajib: Python 3 stdlib saja.
Opsional: `inotifywait` (paket inotify-tools) untuk efisiensi lebih baik.
"""
from __future__ import annotations

import json
import os
import queue
import ssl
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

# --- config dari env -------------------------------------------------------
PANEL_URL  = os.environ.get("PANEL_URL", "").rstrip("/")
REPORT_URL = os.environ.get("REPORT_URL") or (PANEL_URL + "/api/agent/report.php")
AGENT_ID   = os.environ.get("AGENT_ID", "")
API_KEY    = os.environ.get("API_KEY", "")
WATCH_DIR  = os.environ.get("WATCH_DIR", "/var/www/html")
INTERVAL   = max(10, int(os.environ.get("INTERVAL", "30")))
# Mode watcher yang dipaksa: 'auto' (default), 'inotify', atau 'polling'.
WATCH_MODE = os.environ.get("WATCH_MODE", "auto").lower()
# Interval polling dalam detik (kalau fallback polling).
POLL_INTERVAL = max(2, int(os.environ.get("POLL_INTERVAL", "5")))
# Batasi jumlah file yang di-scan dalam mode polling (anti blow-up).
POLL_MAX_FILES = max(1000, int(os.environ.get("POLL_MAX_FILES", "50000")))

if not (REPORT_URL and AGENT_ID and API_KEY):
    print("ERROR: REPORT_URL, AGENT_ID, API_KEY wajib diisi", file=sys.stderr)
    sys.exit(2)

UA = "ehomee-agent/1.0"
SSL_CTX = ssl.create_default_context()
# izinkan self-signed kalau operator eksplisit set ALLOW_INSECURE=1
if os.environ.get("ALLOW_INSECURE") == "1":
    SSL_CTX.check_hostname = False
    SSL_CTX.verify_mode = ssl.CERT_NONE


# --- helpers ---------------------------------------------------------------
def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def read_proc(path: str) -> str:
    try:
        with open(path, "r") as f:
            return f.read()
    except OSError:
        return ""


def collect_metrics() -> dict:
    # uptime
    uptime = 0
    up_raw = read_proc("/proc/uptime").split()
    if up_raw:
        try:
            uptime = int(float(up_raw[0]))
        except ValueError:
            pass

    # load avg
    try:
        load = os.getloadavg()
    except OSError:
        load = (0.0, 0.0, 0.0)

    # memory
    mem = {}
    for line in read_proc("/proc/meminfo").splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            parts = v.strip().split()
            if parts and parts[0].isdigit():
                mem[k] = int(parts[0]) * 1024
    mem_total = mem.get("MemTotal", 0)
    mem_avail = mem.get("MemAvailable", 0)
    mem_used = max(0, mem_total - mem_avail)

    # disk
    try:
        st = os.statvfs(WATCH_DIR)
        disk_total = st.f_frsize * st.f_blocks
        disk_free  = st.f_frsize * st.f_bavail
        disk_used  = disk_total - disk_free
    except OSError:
        disk_total = disk_free = disk_used = 0

    # cpu cores
    cores = 0
    for line in read_proc("/proc/cpuinfo").splitlines():
        if line.startswith("processor"):
            cores += 1

    return {
        "ts": now_iso(),
        "hostname": os.uname().nodename,
        "uptime_sec": uptime,
        "loadavg": [round(x, 2) for x in load],
        "memory": {"total": mem_total, "used": mem_used, "available": mem_avail},
        "disk":   {"path": WATCH_DIR, "total": disk_total, "used": disk_used, "free": disk_free},
        "cpu_cores": cores,
    }


def post_report(metrics: dict | None, events: list[dict]) -> None:
    body = json.dumps({"metrics": metrics, "events": events}).encode("utf-8")
    req = urllib.request.Request(
        REPORT_URL,
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "X-Agent-Id": AGENT_ID,
            "Authorization": "Bearer " + API_KEY,
            "User-Agent": UA,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=15, context=SSL_CTX) as resp:
            _ = resp.read()
    except urllib.error.HTTPError as e:
        print(f"[agent] report HTTP {e.code}: {e.reason}", file=sys.stderr)
    except Exception as e:
        print(f"[agent] report error: {e}", file=sys.stderr)


# --- watcher: inotify (preferred) -----------------------------------------
def _has_inotifywait() -> bool:
    """Cek apakah inotifywait tersedia di PATH."""
    try:
        subprocess.run(
            ["inotifywait", "--help"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            check=False, timeout=3,
        )
        return True
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False


def watcher_inotify(event_q: "queue.Queue[dict]") -> None:
    """Stream event dari inotifywait."""
    Path(WATCH_DIR).mkdir(parents=True, exist_ok=True)
    cmd = [
        "inotifywait", "-m", "-r",
        "-e", "modify,create,delete,move,attrib",
        "--timefmt", "%Y-%m-%dT%H:%M:%SZ",
        "--format", "%T|%w%f|%e",
        WATCH_DIR,
    ]
    print(f"[agent] watcher mode=inotify dir={WATCH_DIR}")
    while True:
        try:
            proc = subprocess.Popen(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                text=True, bufsize=1,
            )
        except FileNotFoundError:
            print("[agent] inotifywait hilang saat runtime, fallback ke polling", file=sys.stderr)
            watcher_polling(event_q)
            return

        assert proc.stdout is not None
        for line in proc.stdout:
            line = line.rstrip("\n")
            if not line or "|" not in line:
                continue
            try:
                ts, path, ev = line.split("|", 2)
            except ValueError:
                continue
            event_q.put({"ts": ts, "path": path, "event": ev})
        proc.wait()
        time.sleep(3)


# --- watcher: polling (fallback murni Python) -----------------------------
def _snapshot(root: str, max_files: int) -> "dict[str, tuple]":
    """Scan WATCH_DIR, return {path: (mtime_ns, size)}. Dibatasi max_files."""
    snap = {}
    try:
        stack = [root]
        count = 0
        while stack and count < max_files:
            cur = stack.pop()
            try:
                with os.scandir(cur) as it:
                    for entry in it:
                        if count >= max_files:
                            break
                        try:
                            if entry.is_dir(follow_symlinks=False):
                                name = entry.name
                                # skip folder berat / irrelevant
                                if name in {".git", "node_modules", "__pycache__", "vendor"}:
                                    continue
                                stack.append(entry.path)
                            else:
                                st = entry.stat(follow_symlinks=False)
                                snap[entry.path] = (st.st_mtime_ns, st.st_size)
                                count += 1
                        except OSError:
                            pass
            except OSError:
                pass
    except Exception as e:
        print(f"[agent] snapshot error: {e}", file=sys.stderr)
    return snap


def watcher_polling(event_q: "queue.Queue[dict]") -> None:
    """Fallback: scan folder tiap POLL_INTERVAL detik, diff mtime+size."""
    Path(WATCH_DIR).mkdir(parents=True, exist_ok=True)
    print(f"[agent] watcher mode=polling dir={WATCH_DIR} interval={POLL_INTERVAL}s max_files={POLL_MAX_FILES}")
    prev = _snapshot(WATCH_DIR, POLL_MAX_FILES)
    while True:
        time.sleep(POLL_INTERVAL)
        try:
            curr = _snapshot(WATCH_DIR, POLL_MAX_FILES)
        except Exception as e:
            print(f"[agent] polling scan error: {e}", file=sys.stderr)
            continue

        ts = now_iso()
        prev_set = set(prev.keys())
        curr_set = set(curr.keys())

        # created
        for p in curr_set - prev_set:
            event_q.put({"ts": ts, "path": p, "event": "CREATE"})
        # deleted
        for p in prev_set - curr_set:
            event_q.put({"ts": ts, "path": p, "event": "DELETE"})
        # modified (mtime atau size berubah)
        for p in curr_set & prev_set:
            if curr[p] != prev[p]:
                event_q.put({"ts": ts, "path": p, "event": "MODIFY"})

        prev = curr


# --- watcher dispatcher ---------------------------------------------------
def watcher_thread(event_q: "queue.Queue[dict]") -> None:
    """Pilih mode watcher berdasarkan WATCH_MODE + ketersediaan inotifywait."""
    mode = WATCH_MODE
    if mode == "auto":
        mode = "inotify" if _has_inotifywait() else "polling"

    if mode == "inotify":
        if not _has_inotifywait():
            print("[agent] WATCH_MODE=inotify tapi inotifywait tidak ada; fallback ke polling", file=sys.stderr)
            watcher_polling(event_q)
        else:
            watcher_inotify(event_q)
    elif mode == "polling":
        watcher_polling(event_q)
    else:
        print(f"[agent] WATCH_MODE={WATCH_MODE} tidak dikenal; pakai polling", file=sys.stderr)
        watcher_polling(event_q)


def drain(q: "queue.Queue[dict]", max_items: int = 200) -> list[dict]:
    out: list[dict] = []
    while len(out) < max_items:
        try:
            out.append(q.get_nowait())
        except queue.Empty:
            break
    return out


# --- main loop -------------------------------------------------------------
def main() -> None:
    print(f"[agent] start id={AGENT_ID} panel={REPORT_URL} watch={WATCH_DIR} interval={INTERVAL}s mode={WATCH_MODE}")
    q: "queue.Queue[dict]" = queue.Queue(maxsize=10000)
    t = threading.Thread(target=watcher_thread, args=(q,), daemon=True)
    t.start()

    # pertama, kirim heartbeat
    post_report(collect_metrics(), [])
    last_tick = time.monotonic()

    while True:
        time.sleep(2)
        events = drain(q)
        now = time.monotonic()
        send_metrics = (now - last_tick) >= INTERVAL
        if events or send_metrics:
            metrics = collect_metrics() if send_metrics else None
            post_report(metrics, events)
            if send_metrics:
                last_tick = now


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
