<?php
require_once __DIR__ . '/../../includes/auth.php';
require_login();
require_csrf();

try {
    $path = safe_path($_POST['path'] ?? '', true);
    if ($path === realpath(cfg()['watch_dir'])) json_fail('tidak bisa menghapus root');

    if (is_dir($path)) {
        // rekursif aman: pastikan semua anak di dalam root
        $root = rtrim(realpath(cfg()['watch_dir']), '/');
        $it = new RecursiveIteratorIterator(
            new RecursiveDirectoryIterator($path, FilesystemIterator::SKIP_DOTS),
            RecursiveIteratorIterator::CHILD_FIRST
        );
        foreach ($it as $f) {
            $p = $f->getRealPath();
            if (strncmp($p, $root . '/', strlen($root) + 1) !== 0) continue;
            $f->isDir() ? rmdir($p) : unlink($p);
        }
        rmdir($path);
    } else {
        unlink($path);
    }
    json_out(['ok' => true]);
} catch (Throwable $e) {
    json_fail($e->getMessage(), 400);
}
