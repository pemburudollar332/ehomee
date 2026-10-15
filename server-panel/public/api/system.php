<?php
require_once __DIR__ . '/../../includes/auth.php';
require_login();

function run(string $cmd): string {
    $out = @shell_exec($cmd . ' 2>&1');
    return is_string($out) ? trim($out) : '';
}

$cfg = cfg();
$watch = $cfg['watch_dir'];

// uptime
$uptimeSec = 0;
if (is_readable('/proc/uptime')) {
    $u = explode(' ', (string)file_get_contents('/proc/uptime'));
    $uptimeSec = (int)floatval($u[0] ?? 0);
}

// load
$load = [0,0,0];
if (function_exists('sys_getloadavg')) $load = sys_getloadavg();

// memory
$mem = [];
if (is_readable('/proc/meminfo')) {
    foreach (file('/proc/meminfo') as $line) {
        if (preg_match('/^(\w+):\s+(\d+)/', $line, $m)) {
            $mem[$m[1]] = (int)$m[2] * 1024; // ke bytes
        }
    }
}
$memTotal = $mem['MemTotal'] ?? 0;
$memAvail = $mem['MemAvailable'] ?? 0;
$memUsed  = max(0, $memTotal - $memAvail);

// disk
$diskTotal = disk_total_space($watch) ?: 0;
$diskFree  = disk_free_space($watch) ?: 0;
$diskUsed  = $diskTotal - $diskFree;

// cpu
$cpuModel = '';
$cpuCores = 0;
if (is_readable('/proc/cpuinfo')) {
    foreach (file('/proc/cpuinfo') as $line) {
        if (strpos($line, 'model name') === 0 && $cpuModel === '') {
            $cpuModel = trim(explode(':', $line, 2)[1] ?? '');
        }
        if (strpos($line, 'processor') === 0) $cpuCores++;
    }
}

// top 5 proses
$top = run("ps -eo pid,user,pcpu,pmem,comm --sort=-pcpu | head -n 6");

json_out([
    'ok' => true,
    'hostname'   => gethostname() ?: '',
    'php'        => PHP_VERSION,
    'os'         => php_uname(),
    'uptime_sec' => $uptimeSec,
    'loadavg'    => $load,
    'memory'     => ['total' => $memTotal, 'used' => $memUsed, 'available' => $memAvail],
    'disk'       => ['path' => $watch, 'total' => $diskTotal, 'used' => $diskUsed, 'free' => $diskFree],
    'cpu'        => ['model' => $cpuModel, 'cores' => $cpuCores],
    'top'        => $top,
    'watch_dir'  => $watch,
]);
