<?php
/**
 * Chips-admin för casino.labnat.se (Stakeless)
 *
 * Lägg filen på valfri sida på samma server, t.ex. labnat.se/chips/index.php.
 * Den pratar med Stakeless API på 127.0.0.1:8798, så databasen behöver inte
 * exponeras. Logga in med ditt Stakeless-konto (som måste vara admin).
 * Alla ändringar hamnar i Stakeless egen adminlogg.
 */

const API = 'http://127.0.0.1:8798/api';
const QUICK_AMOUNTS = [100, 1000, 5000, 10000];

session_start();

// ---------------------------------------------------------------------------
function api(string $method, string $path, ?array $body = null): array
{
    $ch = curl_init(API . $path);
    $headers = ['Accept: application/json'];
    if (!empty($_SESSION['token'])) {
        $headers[] = 'Authorization: Bearer ' . $_SESSION['token'];
    }
    if ($body !== null) {
        $headers[] = 'Content-Type: application/json';
        curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($body));
    }
    curl_setopt_array($ch, [
        CURLOPT_CUSTOMREQUEST  => $method,
        CURLOPT_HTTPHEADER     => $headers,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT        => 10,
    ]);
    $raw    = curl_exec($ch);
    $status = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
    $err    = curl_error($ch);
    curl_close($ch);

    if ($raw === false) {
        return ['status' => 0, 'data' => ['error' => "Kunde inte nå casinot: $err"]];
    }
    return ['status' => $status, 'data' => json_decode($raw, true) ?? []];
}

function h($s): string { return htmlspecialchars((string) $s, ENT_QUOTES, 'UTF-8'); }
function chips($n): string { return number_format((int) $n, 0, ',', ' '); }
function flash(string $type, string $msg): void { $_SESSION['flash'][] = [$type, $msg]; }
function back(array $q = []): void {
    header('Location: ' . strtok($_SERVER['REQUEST_URI'], '?') . ($q ? '?' . http_build_query($q) : ''));
    exit;
}
function logout(string $why = ''): void {
    unset($_SESSION['token']);
    if ($why) flash('error', $why);
    back();
}

if (empty($_SESSION['csrf'])) {
    $_SESSION['csrf'] = bin2hex(random_bytes(16));
}

// ---------------------------------------------------------------------------
// POST-actions
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    if (!hash_equals($_SESSION['csrf'], $_POST['csrf'] ?? '')) {
        flash('error', 'Ogiltig förfrågan, försök igen.');
        back();
    }
    $action = $_POST['action'] ?? '';

    if ($action === 'login') {
        $r = api('POST', '/auth/login', [
            'email'    => trim($_POST['email'] ?? ''),
            'password' => $_POST['password'] ?? '',
        ]);
        if ($r['status'] !== 200 || empty($r['data']['accessToken'])) {
            flash('error', $r['data']['error'] ?? 'Inloggningen misslyckades.');
            back();
        }
        $_SESSION['token'] = $r['data']['accessToken'];
        // Kolla att kontot faktiskt är admin
        $check = api('GET', '/admin/stats');
        if ($check['status'] !== 200) {
            logout('Kontot är inte admin. Kör: ./install-stakeless-cpanel.sh admin <namn>');
        }
        session_regenerate_id(true);
        back();
    }

    if ($action === 'logout') {
        logout();
    }

    if ($action === 'grant') {
        $q      = $_POST['q'] ?? '';
        $id     = (int) ($_POST['id'] ?? 0);
        $name   = $_POST['username'] ?? "#$id";
        $amount = (int) ($_POST['amount'] ?? 0);
        if (($_POST['sign'] ?? '+') === '-') $amount = -abs($amount);

        if ($amount === 0) {
            flash('error', 'Ange ett belopp.');
            back(['q' => $q]);
        }
        $r = api('POST', "/admin/players/$id/grant", ['amount' => $amount]);
        if ($r['status'] === 401) logout('Inloggningen gick ut, logga in igen.');
        if ($r['status'] === 200) {
            $verb = $amount > 0 ? 'Gav' : 'Tog';
            flash('ok', sprintf('%s %s chips %s %s – nytt saldo %s',
                $verb, chips(abs($amount)), $amount > 0 ? 'till' : 'från', $name, chips($r['data']['newBalance'])));
        } else {
            flash('error', $r['data']['error'] ?? 'Något gick fel.');
        }
        back(['q' => $q]);
    }
}

// ---------------------------------------------------------------------------
// Data till vyn
$loggedIn = !empty($_SESSION['token']);
$q        = trim($_GET['q'] ?? '');
$players  = [];
$stats    = null;

if ($loggedIn) {
    // API:t kräver en sökterm; '%' matchar alla (ILIKE '%%%')
    $r = api('GET', '/admin/players?q=' . rawurlencode($q === '' ? '%' : $q));
    if ($r['status'] === 401 || $r['status'] === 403) logout('Inloggningen gick ut, logga in igen.');
    $players = $r['status'] === 200 ? $r['data'] : [];
    if (isset($players['players'])) $players = $players['players'];

    $s = api('GET', '/admin/stats');
    $stats = $s['status'] === 200 ? $s['data'] : null;
}

$flashes = $_SESSION['flash'] ?? [];
unset($_SESSION['flash']);
?>
<!doctype html>
<html lang="sv">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Chips-admin</title>
<style>
  :root {
    --bg: #0f1115; --card: #181b22; --line: #262a33; --text: #e8e9ec; --muted: #8b90a0;
    --gold: #e6b84a; --green: #3ecf8e; --red: #ef5a5a;
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--text);
         font: 15px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif; }
  .wrap { max-width: 920px; margin: 0 auto; padding: 24px 16px 60px; }
  header { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 20px; }
  h1 { font-size: 22px; margin: 0; }
  h1 span { color: var(--gold); }
  .card { background: var(--card); border: 1px solid var(--line); border-radius: 12px; padding: 18px; margin-bottom: 16px; }
  input, select, button { font: inherit; color: inherit; }
  input, select { background: var(--bg); border: 1px solid var(--line); border-radius: 8px; padding: 8px 10px; }
  input:focus, select:focus { outline: 2px solid var(--gold); outline-offset: -1px; }
  button { background: var(--gold); color: #1a1405; border: 0; border-radius: 8px; padding: 8px 14px;
           font-weight: 600; cursor: pointer; }
  button.ghost { background: transparent; color: var(--muted); border: 1px solid var(--line); }
  button.chip { background: #232733; color: var(--text); padding: 6px 10px; font-weight: 500; }
  button.chip:hover { background: #2d3240; }
  .flash { padding: 10px 14px; border-radius: 8px; margin-bottom: 10px; }
  .flash.ok { background: rgba(62,207,142,.12); color: var(--green); }
  .flash.error { background: rgba(239,90,90,.12); color: var(--red); }
  .stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 12px; }
  .stat { background: var(--bg); border-radius: 8px; padding: 12px; }
  .stat b { display: block; font-size: 20px; }
  .stat small { color: var(--muted); }
  .search { display: flex; gap: 8px; }
  .search input { flex: 1; }
  .player { display: grid; grid-template-columns: 1fr auto; gap: 10px 16px; align-items: center;
            padding: 14px 0; border-top: 1px solid var(--line); }
  .player:first-child { border-top: 0; }
  .who b { font-size: 16px; }
  .who small { color: var(--muted); display: block; }
  .bal { font-size: 18px; font-weight: 700; color: var(--gold); text-align: right; white-space: nowrap; }
  .tag { font-size: 11px; padding: 2px 6px; border-radius: 4px; background: #2d3240; color: var(--muted); margin-left: 6px; }
  .tag.ban { background: rgba(239,90,90,.15); color: var(--red); }
  .actions { grid-column: 1 / -1; display: flex; flex-wrap: wrap; gap: 6px; align-items: center; }
  .actions form { display: contents; }
  .custom { display: flex; gap: 6px; margin-left: auto; }
  .custom input { width: 110px; }
  .login { max-width: 360px; margin: 10vh auto; }
  .login input { width: 100%; margin-bottom: 10px; }
  .login button { width: 100%; }
  .muted { color: var(--muted); }
  @media (max-width: 560px) { .custom { margin-left: 0; width: 100%; } .custom input { flex: 1; } }
</style>
</head>
<body>
<div class="wrap">

<?php foreach ($flashes as [$type, $msg]): ?>
  <div class="flash <?= h($type) ?>"><?= h($msg) ?></div>
<?php endforeach; ?>

<?php if (!$loggedIn): ?>
  <div class="card login">
    <h1 style="margin-bottom:6px">🎰 Chips-<span>admin</span></h1>
    <p class="muted" style="margin-top:0">Logga in med ditt casinokonto (admin).</p>
    <form method="post">
      <input type="hidden" name="csrf" value="<?= h($_SESSION['csrf']) ?>">
      <input type="hidden" name="action" value="login">
      <input type="email" name="email" placeholder="E-post" required autofocus>
      <input type="password" name="password" placeholder="Lösenord" required>
      <button type="submit">Logga in</button>
    </form>
  </div>

<?php else: ?>
  <header>
    <h1>🎰 Chips-<span>admin</span></h1>
    <form method="post">
      <input type="hidden" name="csrf" value="<?= h($_SESSION['csrf']) ?>">
      <input type="hidden" name="action" value="logout">
      <button class="ghost">Logga ut</button>
    </form>
  </header>

  <?php if ($stats): ?>
  <div class="card stats">
    <?php
      $labels = [
        'totalUsers' => 'Spelare',
        'totalBets' => 'Spelade rundor',
        'coinsInCirculation' => 'Chips i omlopp',
      ];
      foreach ($stats as $k => $v):
        if (!is_scalar($v)) continue; ?>
      <div class="stat"><b><?= is_numeric($v) ? chips($v) : h($v) ?></b><small><?= h($labels[$k] ?? $k) ?></small></div>
    <?php endforeach; ?>
  </div>
  <?php endif; ?>

  <div class="card">
    <form class="search" method="get">
      <input type="search" name="q" value="<?= h($q) ?>" placeholder="Sök användarnamn (tomt = visa alla)">
      <button>Sök</button>
    </form>
  </div>

  <div class="card">
    <?php if (!$players): ?>
      <p class="muted" style="margin:0">Inga spelare hittades.</p>
    <?php endif; ?>

    <?php foreach ($players as $p): ?>
      <div class="player">
        <div class="who">
          <b><?= h($p['username']) ?></b>
          <?php if (($p['role'] ?? '') === 'admin'): ?><span class="tag">admin</span><?php endif; ?>
          <?php if (!empty($p['isBanned'])): ?><span class="tag ban">bannad</span><?php endif; ?>
          <small><?= h($p['email'] ?? '') ?> · satsat <?= chips($p['totalWagered'] ?? 0) ?></small>
        </div>
        <div class="bal"><?= chips($p['balance']) ?> 🪙</div>

        <div class="actions">
          <?php foreach (QUICK_AMOUNTS as $amt): ?>
            <form method="post">
              <input type="hidden" name="csrf" value="<?= h($_SESSION['csrf']) ?>">
              <input type="hidden" name="action" value="grant">
              <input type="hidden" name="q" value="<?= h($q) ?>">
              <input type="hidden" name="id" value="<?= (int) $p['id'] ?>">
              <input type="hidden" name="username" value="<?= h($p['username']) ?>">
              <input type="hidden" name="amount" value="<?= $amt ?>">
              <button class="chip">+<?= chips($amt) ?></button>
            </form>
          <?php endforeach; ?>

          <form method="post" class="custom">
            <input type="hidden" name="csrf" value="<?= h($_SESSION['csrf']) ?>">
            <input type="hidden" name="action" value="grant">
            <input type="hidden" name="q" value="<?= h($q) ?>">
            <input type="hidden" name="id" value="<?= (int) $p['id'] ?>">
            <input type="hidden" name="username" value="<?= h($p['username']) ?>">
            <select name="sign" aria-label="Ge eller ta">
              <option value="+">Ge</option>
              <option value="-">Ta</option>
            </select>
            <input type="number" name="amount" min="1" max="1000000" placeholder="Antal" required>
            <button>OK</button>
          </form>
        </div>
      </div>
    <?php endforeach; ?>

    <?php if (count($players) >= 20): ?>
      <p class="muted" style="margin:12px 0 0">Visar max 20 – sök på namn för att hitta fler.</p>
    <?php endif; ?>
  </div>
<?php endif; ?>

</div>
</body>
</html>
