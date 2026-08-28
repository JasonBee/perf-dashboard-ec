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
