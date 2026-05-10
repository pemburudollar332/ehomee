<?php
// Loader config. config.local.php dibuat oleh install.sh.
$local = __DIR__ . '/config.local.php';
if (!file_exists($local)) {
    http_response_code(500);
    die('config.local.php tidak ada. Jalankan install.sh lebih dulu.');
}
return require $local;
