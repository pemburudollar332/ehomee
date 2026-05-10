<?php
declare(strict_types=1);

function cfg(): array {
    static $c = null;
    if ($c === null) $c = require __DIR__ . '/config.php';
    return $c;
}

function json_out($data, int $code = 200): void {
    http_response_code($code);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($data, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    exit;
}

function json_fail(string $msg, int $code = 400): void {
    json_out(['ok' => false, 'error' => $msg], $code);
}

/**
 * Resolve path relatif terhadap watch_dir dan pastikan masih di dalamnya.
 * Jika $mustExist=false, hanya parent yang harus exist (untuk upload/mkdir).
 */
function safe_path(string $rel, bool $mustExist = true): string {
    $root = realpath(cfg()['watch_dir']);
    if ($root === false) throw new RuntimeException('watch_dir tidak valid');
    $root = rtrim($root, '/');

    $rel = str_replace('\\', '/', $rel);
    $rel = ltrim($rel, '/');
    $full = $rel === '' ? $root : ($root . '/' . $rel);

    if ($mustExist) {
        $real = realpath($full);
        if ($real === false) throw new RuntimeException('Path tidak ditemukan');
    } else {
        $parent = realpath(dirname($full));
        if ($parent === false) throw new RuntimeException('Parent tidak ada');
        $real = rtrim($parent, '/') . '/' . basename($full);
    }
    if ($real !== $root && strncmp($real, $root . '/', strlen($root) + 1) !== 0) {
        throw new RuntimeException('Path di luar root');
    }
    return $real;
}

function rel_from_root(string $abs): string {
    $root = rtrim(realpath(cfg()['watch_dir']) ?: '', '/');
    if ($abs === $root) return '';
    return ltrim(substr($abs, strlen($root) + 1), '/');
}

function csrf_token(): string {
    if (empty($_SESSION['csrf'])) {
        $_SESSION['csrf'] = bin2hex(random_bytes(16));
    }
    return $_SESSION['csrf'];
}

function require_csrf(): void {
    $t = $_POST['csrf'] ?? $_SERVER['HTTP_X_CSRF_TOKEN'] ?? '';
    if (!hash_equals($_SESSION['csrf'] ?? '', (string)$t)) {
        json_fail('CSRF token invalid', 403);
    }
}

function is_logged_in(): bool {
    return !empty($_SESSION['uid']);
}

function require_login(): void {
    if (is_logged_in()) return;
    $uri = $_SERVER['REQUEST_URI'] ?? '';
    if (str_contains($uri, '/api/')) {
        json_fail('unauthorized', 401);
    }
    header('Location: login.php');
    exit;
}

function is_binary(string $path, int $sample = 4096): bool {
    $fh = @fopen($path, 'rb');
    if (!$fh) return true;
    $buf = fread($fh, $sample);
    fclose($fh);
    if ($buf === false || $buf === '') return false;
    // anggap biner jika ada NUL atau banyak byte non-printable
    if (strpos($buf, "\x00") !== false) return true;
    $bad = preg_match_all('/[^\x09\x0A\x0D\x20-\x7E\xC2-\xF4]/', $buf);
    return $bad > strlen($buf) * 0.3;
}

function human_bytes(int $n): string {
    $u = ['B','KB','MB','GB','TB'];
    $i = 0; $v = $n;
    while ($v >= 1024 && $i < count($u)-1) { $v /= 1024; $i++; }
    return ($i === 0 ? $n : number_format($v, 2)) . ' ' . $u[$i];
}
