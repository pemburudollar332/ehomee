<?php
require_once __DIR__ . '/../../includes/auth.php';
require_login();

$log = cfg()['events_log'];
$limit = max(1, min(500, (int)($_GET['limit'] ?? 100)));

$events = [];
if (is_file($log) && filesize($log) > 0) {
    // baca tail efisien
    $lines = [];
    $fh = fopen($log, 'rb');
    if ($fh) {
        // Simpler: read last 256KB then split
        $size = filesize($log);
        $read = min(256 * 1024, $size);
        fseek($fh, -$read, SEEK_END);
        $chunk = fread($fh, $read);
        fclose($fh);
        $lines = preg_split("/\r?\n/", (string)$chunk);
    }
    $lines = array_values(array_filter($lines, fn($l) => $l !== ''));
    $lines = array_slice($lines, -$limit);
    foreach (array_reverse($lines) as $l) {
        $j = json_decode($l, true);
        if (is_array($j)) $events[] = $j;
    }
}
json_out(['ok' => true, 'events' => $events]);
