#!/usr/bin/env python3
"""
ehomee-agent
Menjalankan:
  - collector: mengumpulkan metrik sistem (uptime, load, mem, disk) tiap INTERVAL detik
  - watcher: memantau WATCH_DIR dengan `inotifywait` dan mengumpulkan event

Lalu push ke REPORT_URL (POST JSON) dengan header:
  X-Agent-Id: <AGENT_ID>
  Authorization: Bearer <API_KEY>

Dikonfigurasi via environment (disuntik systemd EnvironmentFile).
Dependensi: stdlib Python 3 + `inotifywait` (paket inotify-tools).
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


# --- watcher thread --------------------------------------------------------
def watcher_thread(event_q: "queue.Queue[dict]") -> None:
    Path(WATCH_DIR).mkdir(parents=True, exist_ok=True)
    cmd = [
        "inotifywait", "-m", "-r",
        "-e", "modify,create,delete,move,attrib",
        "--timefmt", "%Y-%m-%dT%H:%M:%SZ",
        "--format", "%T|%w%f|%e",
        WATCH_DIR,
    ]
    while True:
        try:
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                bufsize=1,
            )
        except FileNotFoundError:
            print("[agent] inotifywait tidak ditemukan. install paket inotify-tools.", file=sys.stderr)
            time.sleep(30)
            continue

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
        # kalau inotifywait exit (mis. WATCH_DIR hilang), retry
        proc.wait()
        time.sleep(3)


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
    print(f"[agent] start id={AGENT_ID} panel={REPORT_URL} watch={WATCH_DIR} interval={INTERVAL}s")
    q: "queue.Queue[dict]" = queue.Queue(maxsize=10000)
    t = threading.Thread(target=watcher_thread, args=(q,), daemon=True)
    t.start()

    # pertama, kirim heartbeat
    post_report(collect_metrics(), [])
    last_tick = time.monotonic()

    while True:
        # sering kirim event kalau ada, tapi minimum INTERVAL untuk metrics
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
