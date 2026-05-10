<?php
require_once __DIR__ . '/../../includes/auth.php';
require_login();

try {
    $cfg = cfg();
    $max = (int)$cfg['max_edit_bytes'];

    if ($_SERVER['REQUEST_METHOD'] === 'GET') {
        $path = safe_path($_GET['path'] ?? '', true);
        if (is_dir($path)) json_fail('direktori tidak bisa diedit');
        if (filesize($path) > $max) json_fail('file terlalu besar untuk diedit (>' . $max . ' byte)');
        if (is_binary($path)) json_fail('file biner — gunakan Download');
        $content = file_get_contents($path);
        json_out([
            'ok'      => true,
            'content' => $content,
            'path'    => rel_from_root($path),
            'size'    => filesize($path),
        ]);
    }

    if ($_SERVER['REQUEST_METHOD'] === 'POST') {
        require_csrf();
        $path = safe_path($_POST['path'] ?? '', true);
        if (is_dir($path)) json_fail('direktori tidak bisa diedit');
        $content = (string)($_POST['content'] ?? '');
        if (strlen($content) > $max) json_fail('konten melebihi batas');
        if (file_put_contents($path, $content) === false) json_fail('gagal simpan', 500);
        json_out(['ok' => true, 'size' => strlen($content)]);
    }

    json_fail('method tidak didukung', 405);
} catch (Throwable $e) {
    json_fail($e->getMessage(), 400);
}
