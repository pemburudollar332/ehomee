<?php
require_once __DIR__ . '/../../../includes/auth.php';
require_once __DIR__ . '/../../../includes/agents.php';
require_login();
require_csrf();

$id = trim((string)($_POST['id'] ?? ''));
if ($id === '') json_fail('id wajib');

$removed = false;
agents_with_lock(function (array $agents) use ($id, &$removed) {
    $out = [];
    foreach ($agents as $a) {
        if (($a['id'] ?? '') === $id) { $removed = true; continue; }
        $out[] = $a;
    }
    return $out;
});

// Hapus log-nya juga
$logPath = dirname(agents_file()) . '/agent-events/' . preg_replace('/[^a-zA-Z0-9_\-]/', '', $id) . '.log';
if (is_file($logPath)) @unlink($logPath);

json_out(['ok' => true, 'removed' => $removed]);
