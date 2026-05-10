<?php
require_once __DIR__ . '/../includes/auth.php';
$c = cfg();
$err = '';

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $u = trim($_POST['u'] ?? '');
    $p = (string)($_POST['p'] ?? '');
    if ($u === $c['admin_user'] && password_verify($p, $c['admin_pass_hash'])) {
        session_regenerate_id(true);
        $_SESSION['uid'] = $u;
        $_SESSION['ip'] = $_SERVER['REMOTE_ADDR'] ?? '';
        header('Location: index.php');
        exit;
    }
    $err = 'User atau password salah.';
    usleep(600000); // mitigasi brute force ringan
}
?>
<!doctype html>
<html lang="id">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>ehomee panel · login</title>
  <link rel="stylesheet" href="assets/style.css">
</head>
<body class="login">
  <form method="post" class="card login-card" autocomplete="off">
    <h1>ehomee <span class="muted">panel</span></h1>
    <?php if ($err): ?><div class="alert err"><?= htmlspecialchars($err) ?></div><?php endif; ?>
    <label>User
      <input name="u" autofocus required value="<?= htmlspecialchars($_POST['u'] ?? '') ?>">
    </label>
    <label>Password
      <input name="p" type="password" required>
    </label>
    <button class="btn primary" type="submit">Masuk</button>
  </form>
</body>
</html>
