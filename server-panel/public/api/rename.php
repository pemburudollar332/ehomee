<?php
require_once __DIR__ . '/../../includes/auth.php';
require_login();
require_csrf();

try {
    $src = safe_path($_POST['path'] ?? '', true);
    $newName = trim($_POST['name'] ?? '');
    if ($newName === '' || strpos($newName, '/') !== false) json_fail('nama tidak valid');
    $dst = safe_path(rel_from_root(dirname($src)) . '/' . $newName, false);
    if (file_exists($dst)) json_fail('target sudah ada');
    if (!rename($src, $dst)) json_fail('gagal rename', 500);
    json_out(['ok' => true, 'path' => rel_from_root($dst)]);
} catch (Throwable $e) {
    json_fail($e->getMessage(), 400);
}
