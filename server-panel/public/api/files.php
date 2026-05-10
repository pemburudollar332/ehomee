<?php
require_once __DIR__ . '/../../includes/auth.php';
require_login();

try {
    $rel = $_GET['path'] ?? '';
    $dir = safe_path($rel, true);
    if (!is_dir($dir)) json_fail('bukan direktori', 400);

    $items = [];
    $it = new DirectoryIterator($dir);
    foreach ($it as $f) {
        if ($f->isDot()) continue;
        $items[] = [
            'name'   => $f->getFilename(),
            'path'   => rel_from_root($f->getPathname()),
            'is_dir' => $f->isDir(),
            'size'   => $f->isDir() ? null : $f->getSize(),
            'mtime'  => gmdate('c', $f->getMTime()),
            'perm'   => substr(sprintf('%o', $f->getPerms()), -4),
        ];
    }
    // folder dulu, lalu file; alfabet
    usort($items, function ($a, $b) {
        if ($a['is_dir'] !== $b['is_dir']) return $a['is_dir'] ? -1 : 1;
        return strcasecmp($a['name'], $b['name']);
    });

    json_out([
        'ok'    => true,
        'path'  => rel_from_root($dir),
        'items' => $items,
    ]);
} catch (Throwable $e) {
    json_fail($e->getMessage(), 400);
}
