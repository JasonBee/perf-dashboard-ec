#!/usr/bin/env bash
#
# install.sh — SELF-CONTAINED installer for the PHP performance monitor
# =============================================================================
# This single file embeds all four PHP files (perf_start.php, perf_end.php,
# perf-config.php, dashboard.php). No separate bundle needed — just upload
# this one script and run it.
#
# It deploys:
#   1. perf-monitor/   (logger + config)   -> a stable dir ABOVE the web root
#   2. perf-dashboard/ (viewer)            -> a web-accessible dir you choose
#   3. .user.ini       (auto_prepend_file) -> web root + optional app subdir
#
# It rewrites the dashboard's $configPath to the real config location, so the
# viewer always finds its config regardless of where the two dirs end up.
#
# Safe to re-run: it asks before overwriting existing files.
# =============================================================================

set -euo pipefail

c_reset=$'\033[0m'; c_bold=$'\033[1m'; c_dim=$'\033[2m'
c_grn=$'\033[32m';  c_yel=$'\033[33m'; c_red=$'\033[31m'; c_cyn=$'\033[36m'
say()  { printf '%s\n' "$*"; }
info() { printf '%s%s%s\n' "$c_cyn" "$*" "$c_reset"; }
ok()   { printf '%s\xe2\x9c\x93 %s%s\n' "$c_grn" "$*" "$c_reset"; }
warn() { printf '%s! %s%s\n' "$c_yel" "$*" "$c_reset"; }
err()  { printf '%s\xe2\x9c\x97 %s%s\n' "$c_red" "$*" "$c_reset" >&2; }
hr()   { printf '%s%s%s\n' "$c_dim" "----------------------------------------------------------------" "$c_reset"; }

ask() {
    local prompt="$1" default="${2:-}" reply
    if [ -n "$default" ]; then
        read -r -p "$prompt [$default]: " reply || true
        printf '%s' "${reply:-$default}"
    else
        read -r -p "$prompt: " reply || true
        printf '%s' "$reply"
    fi
}
confirm() {
    local reply
    read -r -p "$1 [y/N]: " reply || true
    case "$reply" in [yY]|[yY][eE][sS]) return 0;; *) return 1;; esac
}
set_php_config_path() {
    local file="$1" path="$2" esc
    esc=$(printf '%s' "$path" | sed -e 's/[\/&]/\\&/g')
    sed -i -E "s|^\\\$configPath = .*|\$configPath = '${esc}';|" "$file"
}

hr
info "${c_bold}PHP Performance Monitor — self-contained installer${c_reset}"
hr

HOME_DIR="${HOME:-/home/$(id -un)}"

info "1) Where should the LOGGER live? (perf-monitor/)"
say "   ${c_dim}Put this ABOVE your web root. Holds perf_start.php + perf-config.php.${c_reset}"
MONITOR_DIR="$(ask "   perf-monitor path" "$HOME_DIR/perf-monitor")"
say ""
info "2) Where should the LOG FILES be written? (perf_logs/)"
say "   ${c_dim}ABOVE the web root — logs contain request paths. Auto-created if missing.${c_reset}"
LOG_DIR="$(ask "   log dir path" "$HOME_DIR/perf_logs")"
say ""
info "3) Where should the DASHBOARD be installed? (web-accessible)"
say "   ${c_dim}A directory served by your webserver, e.g. inside the WordPress dir.${c_reset}"
DASH_DIR="$(ask "   perf-dashboard path" "")"
if [ -z "$DASH_DIR" ]; then err "Dashboard path is required."; exit 1; fi
say ""
info "4) Web root (for the auto_prepend_file .user.ini)"
say "   ${c_dim}The document root of the site. Leave blank to skip .user.ini setup.${c_reset}"
WEB_ROOT="$(ask "   web root" "${DOCUMENT_ROOT:-}")"
say ""
APP_SUBDIR=""
if [ -n "$WEB_ROOT" ]; then
    info "5) App subdirectory (optional — for apps that route through a subdir)"
    say "   ${c_dim}e.g. a WordPress install in a subfolder. A 2nd .user.ini goes here.${c_reset}"
    say "   ${c_dim}Leave blank if the app lives directly in the web root.${c_reset}"
    APP_SUBDIR="$(ask "   app subdir (absolute path)" "")"
    say ""
fi
TIMEZONE="$(ask "6) Timezone for logs/dashboard" "UTC")"
say ""

hr
info "Planned installation:"
say "  logger      -> $MONITOR_DIR/"
say "  log files   -> $LOG_DIR/"
say "  dashboard   -> $DASH_DIR/"
say "  timezone    -> $TIMEZONE"
if [ -n "$WEB_ROOT" ]; then
    say "  .user.ini   -> $WEB_ROOT/.user.ini"
    [ -n "$APP_SUBDIR" ] && say "              -> $APP_SUBDIR/.user.ini"
else
    say "  .user.ini   -> (skipped — wire auto_prepend_file yourself)"
fi
hr
confirm "Proceed with these settings?" || { warn "Aborted."; exit 0; }
say ""

mkdir -p "$MONITOR_DIR"
overwrite_ok() { [ ! -e "$1" ] && return 0; confirm "  Overwrite existing $(basename "$1")?"; }

write_perf_start() {
  cat > "$1" <<'PERF_PAYLOAD_EOF'
<?php
/**
 * perf_start.php  —  THE LOGGER (do not edit; edit perf-config.php)
 * ---------------------------------------------------------------------
 * Loaded automatically at the START of every request via auto_prepend_file.
 * Records baseline timing/memory, then registers a shutdown function that
 * writes one JSON line at end of request.
 *
 * WHY A SHUTDOWN FUNCTION (not auto_append_file):
 *   auto_append_file is SKIPPED by PHP when a script ends via exit()/die().
 *   WordPress/MainWP admin pages almost always end that way, so an
 *   append-based logger silently misses them. register_shutdown_function()
 *   runs even after exit()/die(), so it captures every request.
 *
 * Does NOT modify the host application. Overhead: a few microseconds at
 * start; one file append at shutdown.
 * ---------------------------------------------------------------------
 */

if (!defined('PERF_MONITOR_START')) {
    define('PERF_MONITOR_START', microtime(true));
    define('PERF_MONITOR_MEM_START', memory_get_usage());

    // Load shared config (single source of truth). If it's missing or
    // malformed, disable logging silently rather than break the site.
    $perfCfg = @include __DIR__ . '/perf-config.php';
    if (is_array($perfCfg) && !empty($perfCfg['log_dir'])) {

        define('PERF_MONITOR_LOG_DIR',  $perfCfg['log_dir']);
        define('PERF_MONITOR_TIMEZONE', $perfCfg['timezone'] ?? 'UTC');

        register_shutdown_function(function () {
            try {
                // Pin to the configured timezone so the daily filename date
                // and the 'ts' field always agree with the dashboard reader.
                $tz  = new \DateTimeZone(PERF_MONITOR_TIMEZONE);
                $now = new \DateTime('now', $tz);

                $logDir  = PERF_MONITOR_LOG_DIR;
                $logFile = $logDir . '/perf_' . $now->format('Y-m-d') . '.jsonl';

                $duration_ms = round((microtime(true) - PERF_MONITOR_START) * 1000, 2);
                $memory_mb   = round((memory_get_usage() - PERF_MONITOR_MEM_START) / 1048576, 3);
                $peak_mb     = round(memory_get_peak_usage() / 1048576, 3);

                $opcacheHitRate = null;
                if (function_exists('opcache_get_status')) {
                    $status = @opcache_get_status(false);
                    if ($status && isset($status['opcache_statistics']['opcache_hit_rate'])) {
                        $opcacheHitRate = round($status['opcache_statistics']['opcache_hit_rate'], 2);
                    }
                }

                $entry = [
                    'ts'          => $now->format('c'),
                    'path'        => $_SERVER['REQUEST_URI'] ?? 'unknown',
                    'method'      => $_SERVER['REQUEST_METHOD'] ?? 'unknown',
                    'duration_ms' => $duration_ms,
                    'mem_delta_mb'=> $memory_mb,
                    'mem_peak_mb' => $peak_mb,
                    'opcache_hit_rate' => $opcacheHitRate,
                    'http_status' => function_exists('http_response_code') ? http_response_code() : null,
                    'is_ajax'     => (isset($_SERVER['HTTP_X_REQUESTED_WITH']) &&
                                      strtolower($_SERVER['HTTP_X_REQUESTED_WITH']) === 'xmlhttprequest') ? 1 : 0,
                ];

                if (!is_dir($logDir)) {
                    @mkdir($logDir, 0750, true);
                }

                @file_put_contents($logFile, json_encode($entry) . "\n", FILE_APPEND | LOCK_EX);

            } catch (\Throwable $e) {
                // Instrumentation must NEVER break the site. Fail silently.
            }
        });
    }
}
PERF_PAYLOAD_EOF
}

write_perf_end() {
  cat > "$1" <<'PERF_PAYLOAD_EOF'
<?php
/**
 * perf_end.php  —  NO-OP (kept only for compatibility)
 * ---------------------------------------------------------------------
 * All logging happens in perf_start.php via a shutdown function, because
 * auto_append_file is skipped when a script ends via exit()/die() (which
 * WordPress/MainWP admin pages almost always do).
 *
 * KEEP THIS FILE if — as on some shared hosts — a GLOBAL php.ini you
 * cannot edit sets:
 *     auto_append_file = .../perf-monitor/perf_end.php
 * Deleting it would then make PHP emit a warning on every request.
 * With this no-op present, that global append harmlessly does nothing.
 *
 * If YOU control the auto_append_file setting (your own .user.ini or
 * php.ini), simply omit auto_append_file entirely and you can delete
 * this file — perf_start.php does not need it.
 * ---------------------------------------------------------------------
 */

return; // no-op — all logging is handled by perf_start.php
PERF_PAYLOAD_EOF
}

write_perf_config() {
  cat > "$1" <<'PERF_PAYLOAD_EOF'
<?php
/**
 * =====================================================================
 *  perf-config.php  —  EDIT THIS FILE, AND ONLY THIS FILE, PER SITE
 * =====================================================================
 *
 * This is the single source of truth for the performance monitor.
 * Both perf_start.php (the logger) and perf-dashboard/dashboard.php
 * (the viewer) include this file, so every site-specific value lives
 * here in one place. To deploy to a new site, copy the whole set and
 * change the values in the CONFIG block below.
 *
 * Nothing else in perf_start.php or dashboard.php should need editing.
 * ---------------------------------------------------------------------
 */

return [

    /* -----------------------------------------------------------------
     * LOG_DIR  (REQUIRED — change per site)
     * -----------------------------------------------------------------
     * Absolute path to the directory where the .jsonl logs are written
     * and read. Put this ABOVE the web root so raw logs (which contain
     * request paths, and can reveal IDs) are never web-accessible.
     *
     * The logger auto-creates this directory if it doesn't exist.
     * The PHP/FPM user must be able to write here.
     *
     * Example (DreamHost-style home dir):
     *   /home/YOUR_USER/perf_logs
     */
    'log_dir' => '/home/ec_elite_admin/perf_logs',

    /* -----------------------------------------------------------------
     * TIMEZONE  (leave as 'UTC' unless you have a reason not to)
     * -----------------------------------------------------------------
     * Both the logger and the dashboard use this so the daily filename
     * date, the 'ts' field, and the dashboard's date-window all agree.
     * Mixing timezones drops rows logged near midnight. UTC is safest
     * because it never shifts for DST.
     */
    'timezone' => 'UTC',

    /* -----------------------------------------------------------------
     * MIN_SAMPLES  (dashboard only)
     * -----------------------------------------------------------------
     * Minimum number of requests a path needs before it appears in the
     * "slowest endpoints" table. Higher = less noise from one-off hits,
     * but low-traffic pages take longer to surface. 3 is a good default.
     */
    'min_samples' => 3,

    /* -----------------------------------------------------------------
     * SLOW_THRESHOLD_MS  (dashboard only, cosmetic)
     * -----------------------------------------------------------------
     * Rows whose average duration exceeds this are highlighted red in
     * the slowest-endpoints table. Tune to what "slow" means for you.
     */
    'slow_threshold_ms' => 1000,

    /* -----------------------------------------------------------------
     * DASHBOARD_TITLE  (dashboard only, cosmetic)
     * -----------------------------------------------------------------
     * Shown as the <h1> and browser tab title. Handy when you run the
     * monitor on several sites and want to tell the dashboards apart.
     */
    'dashboard_title' => 'Performance Dashboard',

    /* -----------------------------------------------------------------
     * ROUTE_PARAMS  (dashboard only)
     * -----------------------------------------------------------------
     * Query-string keys that identify a distinct endpoint rather than a
     * per-request ID. For these keys, the value is KEPT in the grouping
     * so e.g. admin.php?page=managesites and admin.php?page=Extensions
     * are counted separately. For every other query param, the whole
     * query string is stripped (so ?post=694 and ?post=726 group).
     *
     * WordPress/MainWP defaults: 'page' (admin.php router) and 'action'
     * (admin-ajax.php router). Add your app's router keys if different.
     */
    'route_params' => ['page', 'action'],

    /* -----------------------------------------------------------------
     * SUMMARY CARD COLOR THRESHOLDS  (dashboard only)
     * -----------------------------------------------------------------
     * The four summary cards at the top of the dashboard are colored
     * green / amber / red based on the bands below. Each metric has a
     * "warn" edge (green -> amber) and a "bad" edge (amber -> red):
     *
     *     value <  warn            -> green  (healthy)
     *     warn  <= value <  bad    -> amber  (worth watching)
     *     value >= bad             -> red    (problem)
     *
     * Tune these to what "slow" / "heavy" means for YOUR site. The
     * defaults suit a shared-host WordPress/MainWP dashboard.

     * -- Avg response time (ms) -- the typical request. Tight bands,
     *    because this is an average across every request. */
    'card_avg_ms_warn' => 500,    // green below 500 ms
    'card_avg_ms_bad'  => 1500,   // red at/above 1500 ms

    /* -- 95th percentile (ms) -- the slow tail most users still hit.
     *    Looser than the average, since p95 is expected to run higher. */
    'card_p95_ms_warn' => 1000,   // green below 1000 ms
    'card_p95_ms_bad'  => 3000,   // red at/above 3000 ms

    /* -- Slowest single request (ms) -- a single max value, always
     *    noisy (one cron run or update scan spikes it). Kept loose so
     *    only genuinely pathological outliers turn red. */
    'card_max_ms_warn' => 1500,   // green at/below 1500 ms
    'card_max_ms_bad'  => 4000,   // red above 4000 ms

    /* -- Peak memory -- colored by the MAX observed peak as a PERCENT
     *    of PHP's memory_limit (not absolute MB, which is meaningless
     *    without the limit). If memory_limit can't be read, this card
     *    stays neutral. */
    'card_mem_pct_warn' => 50,    // green below 50% of memory_limit
    'card_mem_pct_bad'  => 80,    // red at/above 80% of memory_limit

];
PERF_PAYLOAD_EOF
}

write_dashboard() {
  cat > "$1" <<'PERF_PAYLOAD_EOF'
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
$configPath = __DIR__ . '/../perf-monitor/perf-config.php';

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

// -- Summary card color thresholds (see perf-config.php for full explanation) --
// Each metric has a warn edge (green->amber) and a bad edge (amber->red):
//     value <  warn          -> green
//     warn  <= value <  bad  -> amber
//     value >= bad           -> red
$cardAvgWarn  = (float)($cfg['card_avg_ms_warn']  ?? 500);
$cardAvgBad   = (float)($cfg['card_avg_ms_bad']   ?? 1500);
$cardP95Warn  = (float)($cfg['card_p95_ms_warn']  ?? 1000);
$cardP95Bad   = (float)($cfg['card_p95_ms_bad']   ?? 3000);
$cardMaxWarn  = (float)($cfg['card_max_ms_warn']  ?? 1500);
$cardMaxBad   = (float)($cfg['card_max_ms_bad']   ?? 4000);
$cardMemWarn  = (float)($cfg['card_mem_pct_warn'] ?? 50);
$cardMemBad   = (float)($cfg['card_mem_pct_bad']  ?? 80);

// Map a value to a card color class using its warn/bad edges. Returns
// 'card-good' | 'card-warn' | 'card-bad'. Higher value = worse.
$cardClass = function ($value, $warn, $bad) {
    if ($value >= $bad)  return 'card-bad';
    if ($value >= $warn) return 'card-warn';
    return 'card-good';
};

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

// Max observed peak as a percent of memory_limit, for the "Avg peak memory"
// card color. null if the limit is unknown/unlimited -> card stays neutral.
$memPeakPct = ($memLimitBytes && $obsPeakBytes)
    ? ($obsPeakBytes / $memLimitBytes) * 100
    : null;

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
  /* Summary card color states (thresholds set in perf-config.php).
     A colored left border + value tint; card background stays white so
     the numbers stay legible. green = healthy, amber = watch, red = problem. */
  .card.card-good { border-left: 4px solid #63991f; }
  .card.card-good .value { color: #3b6d11; }
  .card.card-warn { border-left: 4px solid #ba7517; }
  .card.card-warn .value { color: #854f0b; }
  .card.card-bad  { border-left: 4px solid #c0392b; }
  .card.card-bad  .value { color: #a32d2d; }
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
  <div class="card <?= $cardClass($avgDuration, $cardAvgWarn, $cardAvgBad) ?>"><div class="label">Avg response time</div><div class="value"><?= $avgDuration ?> ms</div></div>
  <div class="card <?= $cardClass($p95, $cardP95Warn, $cardP95Bad) ?>"><div class="label">95th percentile</div><div class="value"><?= $p95 ?> ms</div></div>
  <div class="card <?= $cardClass($maxDuration, $cardMaxWarn, $cardMaxBad) ?>"><div class="label">Slowest single request</div><div class="value"><?= $maxDuration ?> ms</div></div>
  <div class="card <?= $memPeakPct === null ? '' : $cardClass($memPeakPct, $cardMemWarn, $cardMemBad) ?>"><div class="label">Avg peak memory</div><div class="value"><?= $avgMemPeak ?> MB</div></div>
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
PERF_PAYLOAD_EOF
}


# ---- deploy: logger + config ------------------------------------------------
deploy_file() {  # deploy_file <writer_fn> <dest>
    local fn="$1" dest="$2"
    if overwrite_ok "$dest"; then
        "$fn" "$dest"
        ok "installed $dest"
        return 0
    else
        warn "kept existing $dest"
        return 1
    fi
}

deploy_file write_perf_start  "$MONITOR_DIR/perf_start.php"  || true
deploy_file write_perf_end    "$MONITOR_DIR/perf_end.php"    || true

CFG="$MONITOR_DIR/perf-config.php"
deploy_file write_perf_config "$CFG" || true

# Bake log_dir + timezone into perf-config.php
esc_log=$(printf '%s' "$LOG_DIR" | sed -e "s/[\/&]/\\\\&/g")
esc_tz=$(printf '%s' "$TIMEZONE" | sed -e "s/[\/&]/\\\\&/g")
sed -i -E "s|('log_dir'[[:space:]]*=>[[:space:]]*)'[^']*'|\\1'${esc_log}'|" "$CFG"
sed -i -E "s|('timezone'[[:space:]]*=>[[:space:]]*)'[^']*'|\\1'${esc_tz}'|" "$CFG"
ok "config: log_dir=$LOG_DIR, timezone=$TIMEZONE"

# ---- deploy: log dir --------------------------------------------------------
mkdir -p "$LOG_DIR"
chmod 0750 "$LOG_DIR" 2>/dev/null || true
ok "log dir ready: $LOG_DIR"

# ---- deploy: dashboard ------------------------------------------------------
mkdir -p "$DASH_DIR"
DASH_DEST="$DASH_DIR/dashboard.php"
if deploy_file write_dashboard "$DASH_DEST"; then
    set_php_config_path "$DASH_DEST" "$CFG"
    ok "  wired \$configPath -> $CFG"
else
    warn "  dashboard kept; \$configPath NOT rewired — edit it by hand if needed"
fi

# ---- .user.ini --------------------------------------------------------------
if [ -n "$WEB_ROOT" ]; then
    PREPEND="$MONITOR_DIR/perf_start.php"
    write_userini() {
        local dir="$1" ini="$1/.user.ini"
        mkdir -p "$dir"
        if [ -e "$ini" ] && ! confirm "  Overwrite existing $ini?"; then
            warn "kept existing $ini"; return
        fi
        printf 'auto_prepend_file = %s\n' "$PREPEND" > "$ini"
        ok "wrote $ini"
    }
    write_userini "$WEB_ROOT"
    [ -n "$APP_SUBDIR" ] && write_userini "$APP_SUBDIR"
    warn "PHP-FPM caches .user.ini for user_ini.cache_ttl (default 300s)."
    warn "Wait ~5 min or restart PHP before testing."
fi

# ---- optional: password-protect the dashboard -------------------------------
say ""
if confirm "Password-protect the dashboard directory now (.htaccess + .htpasswd)?"; then
    HT_USER="$(ask "  htpasswd username" "admin")"
    HTPASS_FILE="$MONITOR_DIR/.htpasswd_perf"
    if command -v htpasswd >/dev/null 2>&1; then
        htpasswd -c "$HTPASS_FILE" "$HT_USER"
    else
        warn "htpasswd not found; generating with openssl."
        read -r -s -p "  password: " HT_PW; echo
        printf '%s:%s\n' "$HT_USER" "$(openssl passwd -apr1 "$HT_PW")" > "$HTPASS_FILE"
        unset HT_PW
    fi
    cat > "$DASH_DIR/.htaccess" <<HT
AuthType Basic
AuthName "Performance Dashboard"
AuthUserFile $HTPASS_FILE
Require valid-user
HT
    ok "protected $DASH_DIR (user: $HT_USER, file: $HTPASS_FILE)"
else
    warn "Dashboard left UNPROTECTED. It renders request paths — protect it before going live."
fi

# ---- verify -----------------------------------------------------------------
say ""; hr; info "Verifying..."
if command -v php >/dev/null 2>&1; then
    php -l "$MONITOR_DIR/perf_start.php" >/dev/null 2>&1 && ok "perf_start.php syntax OK" || err "perf_start.php syntax error"
    php -l "$DASH_DEST" >/dev/null 2>&1 && ok "dashboard.php syntax OK" || err "dashboard.php syntax error"
    php -r "\$c=include '$CFG'; exit(is_array(\$c)&&!empty(\$c['log_dir'])?0:1);" \
        && ok "perf-config.php loads and has log_dir" || err "perf-config.php problem"
else
    warn "php CLI not found — skipping syntax check. Run 'php -l' on the files after install."
fi
hr

say ""; info "${c_bold}Done.${c_reset} Next:"
say "  1. If you set up .user.ini, wait for the FPM cache (or restart PHP)."
say "  2. Load a few pages on the site to generate log lines."
say "  3. Open the dashboard in your browser."
say "  4. Confirm log files appear in: $LOG_DIR"
if [ -z "$WEB_ROOT" ]; then
    say ""
    warn "You skipped .user.ini. Add this to php.ini or a .user.ini yourself:"
    say "     auto_prepend_file = $MONITOR_DIR/perf_start.php"
fi
say ""

# ---- self-deletion ----------------------------------------------------------
SELF="${BASH_SOURCE[0]}"
if confirm "Delete this installer now?"; then
    ok "removing installer: $SELF"
    rm -f "$SELF"
    exit 0
else
    say "Installer kept at: $SELF"
fi
