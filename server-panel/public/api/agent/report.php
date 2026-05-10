<?php
// Endpoint metrics + events dari agent.
// Header: X-Agent-Id, Authorization: Bearer <api_key>
// Body JSON: { metrics: {...}, events: [ { ts, path, event } ] }

require_once __DIR__ . '/../../../includes/helpers.php';
require_once __DIR__ . '/../../../includes/agents.php';

if ($_SERVER['REQUEST_METHOD'] !== 'POST') json_fail('method not allowed', 405);

$self = agent_authenticate();
$raw = file_get_contents('php://input');
$body = [];
if ($raw !== false && $raw !== '') {
    $body = json_decode($raw, true) ?: [];
}

$metrics = is_array($body['metrics'] ?? null) ? $body['metrics'] : null;
$events  = is_array($body['events']  ?? null) ? $body['events']  : [];
$now = gmdate('c');
$cfg = cfg();

// Normalisasi events + trim max 200 per push
$normalized = [];
foreach ($events as $e) {
    if (!is_array($e)) continue;
    $normalized[] = [
        'ts'    => (string)($e['ts'] ?? $now),
        'path'  => (string)($e['path'] ?? ''),
        'event' => (string)($e['event'] ?? ''),
    ];
    if (count($normalized) >= 200) break;
}

// Per-agent events log (append JSONL)
if ($normalized) {
    $dir = dirname(agents_file()) . '/agent-events';
    if (!is_dir($dir)) @mkdir($dir, 0755, true);
    $logPath = $dir . '/' . preg_replace('/[^a-zA-Z0-9_\-]/', '', $self['id']) . '.log';
    $fp = @fopen($logPath, 'a');
    if ($fp) {
        foreach ($normalized as $e) {
            fwrite($fp, json_encode($e, JSON_UNESCAPED_SLASHES) . "\n");
        }
        fclose($fp);
        // rotate sederhana: kalau > 5 MB, potong ke 2 MB terakhir
        if (filesize($logPath) > 5 * 1024 * 1024) {
            $data = file_get_contents($logPath);
            file_put_contents($logPath, substr($data, -2 * 1024 * 1024));
        }
    }

    // Telegram notification (gabungan)
    if (!empty($cfg['telegram_bot_token']) && !empty($cfg['telegram_chat_id'])) {
        $lines = [];
        foreach (array_slice($normalized, 0, 10) as $e) {
            $lines[] = sprintf('[%s] %s  %s', $e['event'], $e['path'], $e['ts']);
        }
        $rest = count($normalized) - count($lines);
        if ($rest > 0) $lines[] = '... (+' . $rest . ' lagi)';
        $text = "ehomee agent: " . ($self['name'] ?? $self['id']) . "\n" . implode("\n", $lines);
        // fire-and-forget
        $payload = http_build_query([
            'chat_id' => $cfg['telegram_chat_id'],
            'text'    => $text,
            'disable_web_page_preview' => 'true',
        ]);
        $ctx = stream_context_create([
            'http' => [
                'method'  => 'POST',
                'header'  => "Content-Type: application/x-www-form-urlencoded\r\n",
                'content' => $payload,
                'timeout' => 3,
                'ignore_errors' => true,
            ],
        ]);
        @file_get_contents(
            'https://api.telegram.org/bot' . $cfg['telegram_bot_token'] . '/sendMessage',
            false, $ctx
        );
    }
}

agents_with_lock(function (array $agents) use ($self, $metrics, $normalized, $now) {
    foreach ($agents as &$a) {
        if (($a['id'] ?? '') !== $self['id']) continue;
        $a['last_seen'] = $now;
        if ($metrics) $a['last_metrics'] = $metrics;
        // simpan 20 event terakhir di memori (untuk preview di list)
        $buf = $a['last_events'] ?? [];
        foreach ($normalized as $e) {
            $buf[] = $e;
        }
        $a['last_events'] = array_slice($buf, -20);
        break;
    }
    return $agents;
});

json_out([
    'ok' => true,
    'interval' => 30,
    'pong' => $now,
]);
