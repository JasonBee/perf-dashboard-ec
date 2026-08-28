# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.1] — 2026-08-28

### Added
- Version tracking: a `version` key in the config, surfaced in the
  dashboard footer so a running deployment can be traced to a release.
- This changelog.

## [1.0.0] — 2026-08-28

First public release.

### Added
- Per-request logger (`perf_start.php`) that records timing, memory delta,
  peak memory, OPcache hit rate, HTTP status, and AJAX flag to daily
  JSON-lines files. Hooks in via `auto_prepend_file` with no application
  code changes.
- Logging via a shutdown function so requests that end in `exit()`/`die()`
  (most WordPress/MainWP admin pages) are captured — `auto_append_file`
  alone misses these.
- `perf_end.php` no-op, kept only for hosts with an uneditable global
  `auto_append_file` referencing it.
- HTML dashboard (`dashboard.php`): response-time trend chart, slowest-
  endpoints table, and four summary cards (avg, p95, slowest, peak memory).
- Colour-coded summary cards with green/amber/red bands configurable via
  `card_*` thresholds. Peak-memory card colours on max observed peak as a
  percent of `memory_limit`.
- Live health and environment chips (OPcache hit rate and memory, memory
  peak vs limit, max execution time, load average, disk free, PHP version,
  SAPI, server software, timezone, upload/post limits). Each chip is
  guarded and drops silently if its data source is unavailable.
- Endpoint grouping that preserves router query keys (`route_params`,
  default `page` and `action`) so distinct WordPress/MainWP screens are
  counted separately, while stripping per-request IDs.
- UTC-consistent timestamps end-to-end (logger and dashboard read the same
  configured `timezone`), preventing dropped rows near midnight.
- Central `perf-config.php` as the single source of truth for all settings.
- Self-contained installer (`install-perf-dashboard.sh`) that embeds all
  four PHP files, prompts for paths, bakes config, writes `.user.ini`,
  optionally sets up `.htaccess`/`.htpasswd`, verifies with `php -l`, and
  offers self-deletion.
- Version string surfaced in the dashboard footer for traceability.

[1.0.1]: https://github.com/JasonBee/perf-dashboard-ec/releases/tag/v1.0.1
[1.0.0]: https://github.com/JasonBee/perf-dashboard-ec/releases/tag/v1.0.0
