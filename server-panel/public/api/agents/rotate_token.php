<?php
// Rotate enrollment token. Menulis ulang config.local.php secara atomik.
require_once __DIR__ . '/../../../includes/auth.php';
require_once __DIR__ . '/../../../includes/agents.php';
require_login();
require_csrf();

$cfgPath = __DIR__ . '/../../../includes/config.local.php';
if (!is_file($cfgPath) || !is_writable($cfgPath)) json_fail('config.local.php tidak writable', 500);

$cfg = require $cfgPath;
if (!is_array($cfg)) json_fail('config invalid', 500);

$cfg['enrollment_token'] = bin2hex(random_bytes(16));

$exp = "<?php\nreturn " . var_export($cfg, true) . ";\n";
$tmp = $cfgPath . '.tmp';
file_put_contents($tmp, $exp);
@chmod($tmp, 0600);
rename($tmp, $cfgPath);

json_out(['ok' => true, 'enrollment_token' => $cfg['enrollment_token']]);
