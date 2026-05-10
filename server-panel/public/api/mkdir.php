<?php
require_once __DIR__ . '/../../includes/auth.php';
require_login();
require_csrf();

try {
    $rel = trim($_POST['path'] ?? '', '/');
    $name = trim($_POST['name'] ?? '');
    if ($name === '' || strpos($name, '/') !== false) json_fail('nama tidak valid');
    $target = safe_path(($rel === '' ? '' : $rel . '/') . $name, false);
    if (file_exists($target)) json_fail('sudah ada');
    if (!mkdir($target, 0755)) json_fail('gagal membuat folder', 500);
    json_out(['ok' => true, 'path' => rel_from_root($target)]);
} catch (Throwable $e) {
    json_fail($e->getMessage(), 400);
}
