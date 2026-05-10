<?php
// Serve source code agent.sh (pure bash edition, untuk sistem tanpa Python3).
$src = dirname(__DIR__, 2) . '/agent/agent.sh';
if (!is_file($src)) {
    http_response_code(500);
    header('Content-Type: text/plain');
    echo "# ERROR: agent.sh tidak ditemukan di panel.\n";
    exit;
}
header('Content-Type: text/x-shellscript; charset=utf-8');
header('X-Content-Type-Options: nosniff');
readfile($src);
