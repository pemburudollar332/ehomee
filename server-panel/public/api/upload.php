<?php
require_once __DIR__ . '/../../includes/auth.php';
require_login();
require_csrf();

try {
    $rel = $_POST['path'] ?? '';
    $dir = safe_path($rel, true);
    if (!is_dir($dir)) json_fail('bukan direktori', 400);

    if (empty($_FILES['files'])) json_fail('tidak ada file');
    $cfg = cfg();
    $max = (int)$cfg['max_upload_bytes'];

    $saved = [];
    $files = $_FILES['files'];
    $n = is_array($files['name']) ? count($files['name']) : 1;
    for ($i = 0; $i < $n; $i++) {
        $name = is_array($files['name']) ? $files['name'][$i] : $files['name'];
        $tmp  = is_array($files['tmp_name']) ? $files['tmp_name'][$i] : $files['tmp_name'];
        $err  = is_array($files['error']) ? $files['error'][$i] : $files['error'];
        $size = is_array($files['size']) ? $files['size'][$i] : $files['size'];

        if ($err !== UPLOAD_ERR_OK) continue;
        if ($size > $max) continue;

        // sanitize filename
        $base = basename($name);
        $base = preg_replace('/[^A-Za-z0-9._\- ]+/u', '_', $base) ?: 'file';
        $dest = safe_path(trim($rel . '/' . $base, '/'), false);

        // hindari overwrite: tambah sufiks angka
        $final = $dest; $k = 1;
        while (file_exists($final)) {
            $pi = pathinfo($dest);
            $final = ($pi['dirname'] ?? '.') . '/' . ($pi['filename'] ?? 'file')
                   . '-' . $k
                   . (isset($pi['extension']) ? '.' . $pi['extension'] : '');
            $k++;
        }
        if (move_uploaded_file($tmp, $final)) {
            chmod($final, 0644);
            $saved[] = rel_from_root($final);
        }
    }

    json_out(['ok' => true, 'saved' => $saved]);
} catch (Throwable $e) {
    json_fail($e->getMessage(), 400);
}
