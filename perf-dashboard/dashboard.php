<?php
/**
 * dashboard.php  —  THE VIEWER (do not edit; edit perf-config.php)
 * ---------------------------------------------------------------------
 * Reads the perf_YYYY-MM-DD.jsonl logs written by perf_start.php and
 * renders an HTML dashboard: response-time trend, slowest endpoints,
 * memory, request volume.
 *
 * SECURITY: password-protect this directory before going live. It renders
 * request paths, which can include IDs. See README for .htpasswd steps.
 *
 * CONFIG: all settings come from perf-monitor/perf-config.php. The path
 * to that file is resolved relative to this script — adjust ONLY the
 * $configPath line below if you place perf-dashboard somewhere that isn't
 * a sibling of perf-monitor.
 * ---------------------------------------------------------------------
 */

/* -----------------------------------------------------------------
 * CONFIG LOCATION
 * -----------------------------------------------------------------
 * Absolute path to perf-config.php. On this deployment perf-monitor and
 * perf-dashboard are NOT siblings, so an absolute path is used rather
 * than a __DIR__-relative one. If you redeploy elsewhere, set this to
 * wherever perf-config.php lives (absolute path is always safe).
 */
$configPath = '/home/<user>/perf-monitor/perf-config.php';

$cfg = @include $configPath;
if (!is_array($cfg) || empty($cfg['log_dir'])) {
    http_response_code(500);
    echo 'perf-config.php not found or missing log_dir. Looked at: '
       . htmlspecialchars($configPath);
    exit;
}

$logDir          = $cfg['log_dir'];
$timezone        = $cfg['timezone']          ?? 'UTC';
$minSamples      = (int)($cfg['min_samples'] ?? 3);
$slowThresholdMs = (int)($cfg['slow_threshold_ms'] ?? 1000);
$dashboardTitle  = $cfg['dashboard_title']   ?? 'Performance Dashboard';
$routeParams     = $cfg['route_params']      ?? ['page', 'action'];

// Read logs in the SAME timezone they were written in, or requests logged
// after midnight land in a file this loop won't open.
date_default_timezone_set($timezone);

$daysBack = isset($_GET['days']) ? max(1, min(30, (int)$_GET['days'])) : 7;

$rows = [];
for ($i = 0; $i < $daysBack; $i++) {
    $date = date('Y-m-d', strtotime("-$i days"));
    $file = $logDir . "/perf_$date.jsonl";
    if (!is_file($file)) continue;

    $lines = @file($file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    if (!$lines) continue;

    foreach ($lines as $line) {
        $decoded = json_decode($line, true);
        if ($decoded) $rows[] = $decoded;
    }
}

// ---- Aggregate: hourly average duration for the trend chart ----
$hourly = []; // 'YYYY-MM-DDTHH' => ['sum' => x, 'count' => y]
foreach ($rows as $r) {
    $hourKey = substr($r['ts'], 0, 13);
    if (!isset($hourly[$hourKey])) {
        $hourly[$hourKey] = ['sum' => 0, 'count' => 0];
    }
    $hourly[$hourKey]['sum']   += $r['duration_ms'];
    $hourly[$hourKey]['count']++;
}
ksort($hourly);

$trendLabels = [];
$trendValues = [];
foreach ($hourly as $hour => $agg) {
    $trendLabels[] = $hour;
    $trendValues[] = round($agg['sum'] / $agg['count'], 1);
}

// ---- Aggregate: slowest endpoints (by average duration, min N samples) ----
$byPath = [];

// Normalize a request URI into a grouping key. By default the query string
// is stripped so per-request IDs (?post=694 vs ?post=726) group together.
// But for router endpoints listed in $routeParams the query value IS the
// endpoint identity, so it's kept (admin.php?page=X vs admin.php?page=Y).
$normalizePath = function ($uri) use ($routeParams) {
    $base = strtok($uri, '?');
    $qs   = parse_url($uri, PHP_URL_QUERY);
    if ($qs === null || $qs === false || $qs === '') {
        return $base;
    }
    parse_str($qs, $params);
    foreach ($routeParams as $routeKey) {
        if (isset($params[$routeKey]) && $params[$routeKey] !== '') {
            $val = preg_replace('/[^A-Za-z0-9_\-]/', '', (string)$params[$routeKey]);
            if ($val !== '') {
                return $base . '?' . $routeKey . '=' . $val;
            }
        }
    }
    return $base;
};

foreach ($rows as $r) {
    $path = $normalizePath($r['path']);
    if (!isset($byPath[$path])) {
        $byPath[$path] = ['sum' => 0, 'count' => 0, 'max' => 0];
    }
    $byPath[$path]['sum']   += $r['duration_ms'];
    $byPath[$path]['count']++;
    $byPath[$path]['max']    = max($byPath[$path]['max'], $r['duration_ms']);
}

$slowest = [];
foreach ($byPath as $path => $agg) {
    if ($agg['count'] < $minSamples) continue;
    $slowest[] = [
        'path'    => $path,
        'avg_ms'  => round($agg['sum'] / $agg['count'], 1),
        'max_ms'  => $agg['max'],
        'count'   => $agg['count'],
    ];
}
usort($slowest, fn($a, $b) => $b['avg_ms'] <=> $a['avg_ms']);
$slowest = array_slice($slowest, 0, 15);

// ---- Summary stats ----
$totalRequests = count($rows);
$avgDuration   = $totalRequests ? round(array_sum(array_column($rows, 'duration_ms')) / $totalRequests, 1) : 0;
$maxDuration   = $totalRequests ? max(array_column($rows, 'duration_ms')) : 0;
$avgMemPeak    = $totalRequests ? round(array_sum(array_column($rows, 'mem_peak_mb')) / $totalRequests, 2) : 0;

$durations = array_column($rows, 'duration_ms');
sort($durations);
$p95 = $totalRequests ? $durations[(int)floor(0.95 * ($totalRequests - 1))] : 0;

// ---- Environment & live-health chips ------------------------------------
// Everything here is read live from the environment the dashboard runs in.
// Each value is guarded: if a function is disabled on the host (common on
// shared hosting for sys_getloadavg / disk_free_space), its chip is skipped
// rather than erroring. No new logging and no DB/WordPress calls.

$fmtBytes = function ($bytes) {
    if (!is_numeric($bytes) || $bytes < 0) return null;
    $units = ['B', 'KB', 'MB', 'GB', 'TB'];
    $i = 0;
    $b = (float)$bytes;
    while ($b >= 1024 && $i < count($units) - 1) { $b /= 1024; $i++; }
    return round($b, $b >= 10 || $i === 0 ? 0 : 1) . ' ' . $units[$i];
};

// Convert a php.ini shorthand size (e.g. "128M", "512K", "2G") to bytes.
$iniBytes = function ($val) {
    $val = trim((string)$val);
    if ($val === '') return null;
    $unit = strtolower($val[strlen($val) - 1]);
    $num  = (float)$val;
    switch ($unit) {
        case 'g': $num *= 1024; // fall through
        case 'm': $num *= 1024; // fall through
        case 'k': $num *= 1024;
    }
    return (int)$num;
};

// -- Live health --
$opcacheHitLive = null;
$opcacheMemUsed = null;
$opcacheMemTotal = null;
if (function_exists('opcache_get_status')) {
    $ocs = @opcache_get_status(false);
    if (is_array($ocs)) {
        if (isset($ocs['opcache_statistics']['opcache_hit_rate'])) {
            $opcacheHitLive = round($ocs['opcache_statistics']['opcache_hit_rate'], 1);
        }
        if (isset($ocs['memory_usage']['used_memory'], $ocs['memory_usage']['free_memory'])) {
            $opcacheMemUsed  = $ocs['memory_usage']['used_memory'];
            $opcacheMemTotal = $ocs['memory_usage']['used_memory'] + $ocs['memory_usage']['free_memory'];
        }
    }
}

$memLimitBytes = $iniBytes(ini_get('memory_limit'));           // null if unlimited "-1"
$obsPeakBytes  = $totalRequests ? (max(array_column($rows, 'mem_peak_mb')) * 1048576) : 0;

$loadAvg = null;
if (function_exists('sys_getloadavg')) {
    $la = @sys_getloadavg();
    if (is_array($la) && isset($la[0])) $loadAvg = round($la[0], 2);
}

$diskFree = @disk_free_space($logDir);
if ($diskFree === false) $diskFree = null;

$maxExec = ini_get('max_execution_time');

// -- Environment --
$phpVersion   = PHP_VERSION;
$sapi         = php_sapi_name();
$serverSw     = $_SERVER['SERVER_SOFTWARE'] ?? null;
$hostName     = $_SERVER['SERVER_NAME'] ?? ($_SERVER['HTTP_HOST'] ?? 'unknown');
$uploadMax    = ini_get('upload_max_filesize');
$postMax      = ini_get('post_max_size');

// Page title: "Performance Dashboard - <FQDN>". If dashboard_title is set in
// config to something other than the default, that override wins.
$defaultTitle = 'Performance Dashboard';
if (!empty($cfg['dashboard_title']) && $cfg['dashboard_title'] !== $defaultTitle) {
    $pageTitle = $cfg['dashboard_title'];
} else {
    $pageTitle = 'Performance Dashboard - ' . ($_SERVER['SERVER_NAME'] ?? ($_SERVER['HTTP_HOST'] ?? 'Site'));
}

?><!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title><?= htmlspecialchars($pageTitle) ?></title>
<script src="https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.0/chart.umd.min.js"></script>
<style>
  body { font-family: -apple-system, Segoe UI, Roboto, sans-serif; background: #f4f5f7; margin: 0; padding: 24px; color: #1a1a1a; }
  h1 { font-size: 20px; margin-bottom: 4px; }
  .subtitle { color: #666; font-size: 13px; margin-bottom: 24px; }
  .cards { display: flex; gap: 16px; margin-bottom: 24px; flex-wrap: wrap; }
  .card { background: #fff; border-radius: 8px; padding: 16px 20px; box-shadow: 0 1px 3px rgba(0,0,0,0.08); min-width: 140px; }
  .card .label { font-size: 12px; color: #777; text-transform: uppercase; letter-spacing: 0.03em; }
  .card .value { font-size: 26px; font-weight: 600; margin-top: 4px; }
  .panel { background: #fff; border-radius: 8px; padding: 20px; box-shadow: 0 1px 3px rgba(0,0,0,0.08); margin-bottom: 24px; }
  .panel h2 { font-size: 15px; margin: 0 0 16px 0; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid #eee; }
  th { color: #777; font-weight: 500; font-size: 12px; text-transform: uppercase; }
  .slow { color: #c0392b; font-weight: 600; }
  .filters { margin-bottom: 20px; }
  .filters a { margin-right: 8px; padding: 6px 12px; border-radius: 6px; background: #fff; text-decoration: none; color: #333; font-size: 13px; border: 1px solid #ddd; }
  .filters a.active { background: #1a1a1a; color: #fff; border-color: #1a1a1a; }
  .chip-label { font-size: 11px; color: #999; text-transform: uppercase; letter-spacing: 0.04em; margin-bottom: 8px; }
  .chip-row { display: flex; flex-wrap: wrap; gap: 8px; padding: 14px 16px; background: #fff; border: 1px solid #eee; border-radius: 12px; margin-bottom: 16px; }
  .chip { display: flex; align-items: center; gap: 6px; padding: 5px 10px; background: #f4f5f7; border-radius: 8px; font-size: 12px; color: #555; }
  .chip .k { color: #999; }
  .chip .v { font-weight: 600; color: #1a1a1a; }
  .chip.accent { background: #e6f1fb; color: #185fa5; }
  .chip.accent .k { color: #185fa5; opacity: 0.75; }
  .chip.accent .v { color: #0c447c; }
  .chip.good { background: #eaf3de; color: #3b6d11; }
  .chip.good .k { color: #3b6d11; opacity: 0.75; }
  .chip.good .v { color: #27500a; }
  .chip.warn { background: #faeeda; color: #854f0b; }
  .chip.warn .k { color: #854f0b; opacity: 0.75; }
  .chip.warn .v { color: #633806; }
</style>
</head>
<body>

<h1><?= htmlspecialchars($pageTitle) ?></h1>
<div class="subtitle">Last <?= $daysBack ?> day(s) &middot; <?= $totalRequests ?> requests logged &middot; times in <?= htmlspecialchars($timezone) ?></div>

<div class="filters">
  <a href="?days=1"  class="<?= $daysBack==1  ? 'active' : '' ?>">Today</a>
  <a href="?days=7"  class="<?= $daysBack==7  ? 'active' : '' ?>">7 days</a>
  <a href="?days=30" class="<?= $daysBack==30 ? 'active' : '' ?>">30 days</a>
</div>

<div class="cards">
  <div class="card"><div class="label">Avg response time</div><div class="value"><?= $avgDuration ?> ms</div></div>
  <div class="card"><div class="label">95th percentile</div><div class="value"><?= $p95 ?> ms</div></div>
  <div class="card"><div class="label">Slowest single request</div><div class="value"><?= $maxDuration ?> ms</div></div>
  <div class="card"><div class="label">Avg peak memory</div><div class="value"><?= $avgMemPeak ?> MB</div></div>
</div>

<?php
// Peak-vs-limit warning colour: amber if observed peak >= 75% of the limit.
$peakWarn = ($memLimitBytes && $obsPeakBytes >= 0.75 * $memLimitBytes);
// OPcache hit colour: green >= 90%, amber below.
$hitGood  = ($opcacheHitLive !== null && $opcacheHitLive >= 90);
?>
<div class="chip-label">Live health</div>
<div class="chip-row">
  <?php if ($opcacheHitLive !== null): ?>
    <div class="chip <?= $hitGood ? 'good' : 'warn' ?>"><span class="k">OPcache hit</span><span class="v"><?= $opcacheHitLive ?>%</span></div>
  <?php endif; ?>
  <?php if ($opcacheMemUsed !== null && $opcacheMemTotal): ?>
    <div class="chip"><span class="k">OPcache mem</span><span class="v"><?= $fmtBytes($opcacheMemUsed) ?> / <?= $fmtBytes($opcacheMemTotal) ?></span></div>
  <?php endif; ?>
  <?php if ($memLimitBytes && $obsPeakBytes): ?>
    <div class="chip <?= $peakWarn ? 'warn' : '' ?>"><span class="k">peak vs limit</span><span class="v"><?= $fmtBytes($obsPeakBytes) ?> / <?= $fmtBytes($memLimitBytes) ?></span></div>
  <?php endif; ?>
  <?php if ($maxExec !== false && $maxExec !== ''): ?>
    <div class="chip"><span class="k">max exec</span><span class="v"><?= (int)$maxExec ?>s</span></div>
  <?php endif; ?>
  <?php if ($loadAvg !== null): ?>
    <div class="chip"><span class="k">load avg</span><span class="v"><?= $loadAvg ?></span></div>
  <?php endif; ?>
  <?php if ($diskFree !== null): ?>
    <div class="chip"><span class="k">disk free</span><span class="v"><?= $fmtBytes($diskFree) ?></span></div>
  <?php endif; ?>
</div>

<div class="chip-label">Environment</div>
<div class="chip-row">
  <div class="chip accent"><span class="k">host</span><span class="v"><?= htmlspecialchars($hostName) ?></span></div>
  <div class="chip"><span class="k">PHP</span><span class="v"><?= htmlspecialchars($phpVersion) ?></span></div>
  <div class="chip"><span class="k">SAPI</span><span class="v"><?= htmlspecialchars($sapi) ?></span></div>
  <?php if ($serverSw): ?>
    <div class="chip"><span class="k">server</span><span class="v"><?= htmlspecialchars(strtok($serverSw, ' ')) ?></span></div>
  <?php endif; ?>
  <div class="chip"><span class="k">tz</span><span class="v"><?= htmlspecialchars($timezone) ?></span></div>
  <?php if ($uploadMax): ?>
    <div class="chip"><span class="k">upload max</span><span class="v"><?= htmlspecialchars($uploadMax) ?></span></div>
  <?php endif; ?>
  <?php if ($postMax): ?>
    <div class="chip"><span class="k">post max</span><span class="v"><?= htmlspecialchars($postMax) ?></span></div>
  <?php endif; ?>
</div>

<div class="panel">
  <h2>Average response time by hour</h2>
  <canvas id="trendChart" height="80"></canvas>
</div>

<div class="panel">
  <h2>Slowest pages/endpoints (avg over &ge;<?= $minSamples ?> requests)</h2>
  <?php if (empty($slowest)): ?>
    <p style="color:#888; font-size:13px;">Not enough data yet — check back after some usage has been logged.</p>
  <?php else: ?>
  <table>
    <tr><th>Path</th><th>Avg (ms)</th><th>Max (ms)</th><th>Requests</th></tr>
    <?php foreach ($slowest as $s): ?>
    <tr>
      <td><?= htmlspecialchars($s['path']) ?></td>
      <td class="<?= $s['avg_ms'] > $slowThresholdMs ? 'slow' : '' ?>"><?= $s['avg_ms'] ?></td>
      <td><?= $s['max_ms'] ?></td>
      <td><?= $s['count'] ?></td>
    </tr>
    <?php endforeach; ?>
  </table>
  <?php endif; ?>
</div>

<script>
new Chart(document.getElementById('trendChart'), {
  type: 'line',
  data: {
    labels: <?= json_encode($trendLabels) ?>,
    datasets: [{
      label: 'Avg ms',
      data: <?= json_encode($trendValues) ?>,
      borderColor: '#4F17A8',
      backgroundColor: 'rgba(79,23,168,0.08)',
      fill: true,
      tension: 0.25,
      pointRadius: 2
    }]
  },
  options: {
    responsive: true,
    plugins: { legend: { display: false } },
    scales: { y: { beginAtZero: true, title: { display: true, text: 'ms' } } }
  }
});
</script>

</body>
</html>
