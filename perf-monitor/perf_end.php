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
