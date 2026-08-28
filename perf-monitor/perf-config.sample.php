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
     *   /home/<user>/perf_logs
     */
    'log_dir' => '/home/<user>/perf_logs',

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

];
