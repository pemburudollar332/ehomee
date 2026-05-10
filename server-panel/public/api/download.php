<?php
require_once __DIR__ . '/../../includes/auth.php';
require_login();

try {
    $path = safe_path($_GET['path'] ?? '', true);
    if (is_dir($path)) { http_response_code(400); echo 'direktori'; exit; }
    $name = basename($path);
    header('Content-Type: application/octet-stream');
    header('Content-Length: ' . filesize($path));
    header('Content-Disposition: attachment; filename="' . str_replace('"', '', $name) . '"');
    header('X-Content-Type-Options: nosniff');
    readfile($path);
} catch (Throwable $e) {
    http_response_code(400);
    echo htmlspecialchars($e->getMessage());
}
