<?php
require_once __DIR__ . '/../../../includes/auth.php';
require_once __DIR__ . '/../../../includes/agents.php';
require_login();

$agents = agents_load();
$out = [];
foreach ($agents as $a) {
    unset($a['api_key_hash']);
    $a['status'] = agent_status($a);
    $out[] = $a;
}

json_out([
    'ok'                => true,
    'agents'            => $out,
    'enrollment_token'  => enrollment_token(),
    'install_url'       => panel_base_url() . '/api/install.sh.php',
    'panel_url'         => panel_base_url(),
]);
