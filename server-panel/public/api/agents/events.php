<?php
require_once __DIR__ . '/../../../includes/auth.php';
require_once __DIR__ . '/../../../includes/agents.php';
require_login();

$id = trim((string)($_GET['id'] ?? ''));
if ($id === '') json_fail('id wajib');
$limit = max(1, min(500, (int)($_GET['limit'] ?? 100)));

$logPath = dirname(agents_file()) . '/agent-events/' . preg_replace('/[^a-zA-Z0-9_\-]/', '', $id) . '.log';
$events = [];
if (is_file($logPath) && filesize($logPath) > 0) {
    $size = filesize($logPath);
    $read = min(256 * 1024, $size);
    $fh = fopen($logPath, 'rb');
    if ($fh) {
        fseek($fh, -$read, SEEK_END);
        $chunk = fread($fh, $read);
        fclose($fh);
        $lines = array_values(array_filter(preg_split("/\r?\n/", (string)$chunk), fn($l) => $l !== ''));
        $lines = array_slice($lines, -$limit);
        foreach (array_reverse($lines) as $l) {
            $j = json_decode($l, true);
            if (is_array($j)) $events[] = $j;
        }
    }
}

json_out(['ok' => true, 'events' => $events]);
