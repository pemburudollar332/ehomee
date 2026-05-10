<?php
// Penyimpanan data agent ringan berbasis JSON file.
// Setiap agent: { id, name, api_key_hash, os, arch, registered_at, last_seen, last_metrics, last_events[], enroll_ip }
declare(strict_types=1);

require_once __DIR__ . '/helpers.php';

function agents_file(): string {
    $c = cfg();
    return $c['agents_file'] ?? (dirname(__DIR__) . '/data/agents.json');
}

function agents_load(): array {
    $f = agents_file();
    if (!file_exists($f)) return [];
    $raw = file_get_contents($f);
    if ($raw === false || $raw === '') return [];
    $data = json_decode($raw, true);
    return is_array($data) ? $data : [];
}

function agents_save(array $data): void {
    $f = agents_file();
    $dir = dirname($f);
    if (!is_dir($dir)) @mkdir($dir, 0755, true);
    $tmp = $f . '.tmp';
    file_put_contents($tmp, json_encode($data, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));
    @chmod($tmp, 0640);
    rename($tmp, $f);
}

function agents_with_lock(callable $fn) {
    $f = agents_file();
    $dir = dirname($f);
    if (!is_dir($dir)) @mkdir($dir, 0755, true);
    $lock = fopen($f . '.lock', 'c');
    if (!$lock) throw new RuntimeException('lock gagal');
    flock($lock, LOCK_EX);
    try {
        $data = agents_load();
        $res = $fn($data);
        if ($res !== null) agents_save($res);
        return $data;
    } finally {
        flock($lock, LOCK_UN);
        fclose($lock);
    }
}

function agent_hash_key(string $key): string {
    return hash('sha256', $key);
}

function agent_find_by_id(array $agents, string $id): ?array {
    foreach ($agents as $a) if (($a['id'] ?? '') === $id) return $a;
    return null;
}

function agent_authenticate(): array {
    // Header: X-Agent-Id + Authorization: Bearer <api_key>
    $id = $_SERVER['HTTP_X_AGENT_ID'] ?? '';
    $auth = $_SERVER['HTTP_AUTHORIZATION'] ?? '';
    if ($id === '' || !preg_match('/^Bearer\s+(.+)$/i', $auth, $m)) {
        json_fail('unauthorized', 401);
    }
    $key = trim($m[1]);
    $agents = agents_load();
    $a = agent_find_by_id($agents, $id);
    if (!$a || !hash_equals($a['api_key_hash'] ?? '', agent_hash_key($key))) {
        json_fail('invalid credentials', 401);
    }
    return $a;
}

function agent_status(array $a, int $offlineAfter = 120): string {
    $last = strtotime((string)($a['last_seen'] ?? '')) ?: 0;
    if ($last === 0) return 'pending';
    return (time() - $last) < $offlineAfter ? 'online' : 'offline';
}

function enrollment_token(): string {
    $c = cfg();
    return (string)($c['enrollment_token'] ?? '');
}

function panel_base_url(): string {
    $scheme = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') ? 'https' : 'http';
    $host = $_SERVER['HTTP_HOST'] ?? 'localhost';
    return $scheme . '://' . $host;
}
