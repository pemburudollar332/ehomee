<?php
// Serve source code agent.py. File live ada di ../../agent/agent.py
// Tidak butuh auth — kontennya publik (sudah di-review di repo).
$src = dirname(__DIR__, 2) . '/agent/agent.py';
if (!is_file($src)) {
    http_response_code(500);
    header('Content-Type: text/plain');
    echo "# ERROR: agent.py tidak ditemukan di panel.\n";
    exit;
}
header('Content-Type: text/x-python; charset=utf-8');
header('X-Content-Type-Options: nosniff');
readfile($src);
