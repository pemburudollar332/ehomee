<?php
// Serve skrip installer agent yang sudah di-template dengan URL panel + token.
// Panggilan: GET /api/install.sh.php?token=<enrollment>&name=<server-name>
// Token enrollment wajib dan harus cocok dengan config.

require_once __DIR__ . '/../../includes/helpers.php';
require_once __DIR__ . '/../../includes/agents.php';

header('Content-Type: text/x-shellscript; charset=utf-8');
header('X-Content-Type-Options: nosniff');

$token = (string)($_GET['token'] ?? '');
if (!enrollment_token() || !hash_equals(enrollment_token(), $token)) {
    http_response_code(401);
    echo "#!/usr/bin/env bash\necho 'ERROR: enrollment token invalid atau belum di-set di panel.' >&2\nexit 1\n";
    exit;
}

$name     = preg_replace('/[^A-Za-z0-9._-]/', '-', (string)($_GET['name'] ?? '')) ?: '';
$watch    = (string)($_GET['watch'] ?? 'auto');
// Izinkan nilai khusus 'auto' untuk auto-detect di installer.
if ($watch === '') $watch = 'auto';
$method   = (string)($_GET['method'] ?? 'auto');
if (!in_array($method, ['auto','systemd-system','systemd-user','cron','nohup'], true)) {
    $method = 'auto';
}
$panelUrl = panel_base_url();

$tplPath = dirname(__DIR__, 2) . '/agent/install-agent.sh';
$tpl = is_file($tplPath) ? file_get_contents($tplPath) : '';
if ($tpl === '') {
    http_response_code(500);
    echo "#!/usr/bin/env bash\necho 'ERROR: template install-agent.sh tidak ditemukan.' >&2\nexit 1\n";
    exit;
}

$repls = [
    '__PANEL_URL__'     => $panelUrl,
    '__ENROLL_TOKEN__'  => enrollment_token(),
    '__AGENT_NAME__'    => $name,
    '__WATCH_DIR__'     => $watch,
    '__METHOD__'        => $method,
];
echo strtr($tpl, $repls);
