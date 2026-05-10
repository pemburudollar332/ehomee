<?php
// Endpoint enrollment agent.
// Body (POST form/json): name, hostname, os, arch, watch_dir, version
// Header: X-Enroll-Token: <enrollment_token>
// Response: { ok, agent_id, api_key }

require_once __DIR__ . '/../../../includes/helpers.php';
require_once __DIR__ . '/../../../includes/agents.php';

if ($_SERVER['REQUEST_METHOD'] !== 'POST') json_fail('method not allowed', 405);

$token = $_SERVER['HTTP_X_ENROLL_TOKEN'] ?? '';
if (!enrollment_token() || !hash_equals(enrollment_token(), (string)$token)) {
    json_fail('invalid enrollment token', 401);
}

// Terima form-encoded atau JSON
$raw = file_get_contents('php://input');
$body = [];
if ($raw !== false && $raw !== '' && stripos($_SERVER['CONTENT_TYPE'] ?? '', 'json') !== false) {
    $body = json_decode($raw, true) ?: [];
} else {
    $body = $_POST;
}

$name = trim((string)($body['name'] ?? ''));
if ($name === '') $name = trim((string)($body['hostname'] ?? 'unnamed'));
$hostname = trim((string)($body['hostname'] ?? ''));
$os       = trim((string)($body['os'] ?? ''));
$arch     = trim((string)($body['arch'] ?? ''));
$watch    = trim((string)($body['watch_dir'] ?? ''));
$version  = trim((string)($body['version'] ?? ''));
$instUser = trim((string)($body['install_user'] ?? ''));
$instMeth = trim((string)($body['install_method'] ?? ''));

$api_key  = bin2hex(random_bytes(24));
$agent_id = 'agt_' . bin2hex(random_bytes(8));
$now = gmdate('c');
$ip  = $_SERVER['REMOTE_ADDR'] ?? '';

agents_with_lock(function (array $agents) use (
    $agent_id, $name, $hostname, $os, $arch, $watch, $version, $api_key, $now, $ip, $instUser, $instMeth
) {
    $agents[] = [
        'id'             => $agent_id,
        'name'           => $name,
        'hostname'       => $hostname,
        'os'             => $os,
        'arch'           => $arch,
        'watch_dir'      => $watch,
        'version'        => $version,
        'install_user'   => $instUser,
        'install_method' => $instMeth,
        'api_key_hash'   => agent_hash_key($api_key),
        'registered_at'  => $now,
        'last_seen'      => null,
        'last_metrics'   => null,
        'last_events'    => [],
        'enroll_ip'      => $ip,
    ];
    return $agents;
});

json_out([
    'ok'        => true,
    'agent_id'  => $agent_id,
    'api_key'   => $api_key,
    'report_url'=> panel_base_url() . '/api/agent/report.php',
    'interval'  => 30,
]);
