# Changelog

## [0.2.0] - 2026-06-28

### Added

- **Context support with full UI integration** (closes #12)
  - TaskContext model with id, name, searchQuery, writeQuery
  - Context persistence per profile
  - Composite effective search query (context filters AND user filters)
  - Write query defaults pre-fill task editor (tags, project, priority)
  - Context switcher chip in top bar with define/edit/delete dialogs
  - Redesigned AppBar: profile avatar → drawer, context switcher title, sync-only actions
  - Search icon dot shown only for manual search/filters, not context changes
  - clearFilters no longer resets active context

- **Query language engine and structural filters**
  - Recursive-descent parser with AND, OR, NOT grouping and parentheses
  - Terms: tag, project, status, priority, UDA, flag, date
  - Comparison operators (`after:`, `before:`, `is:`, `isnt:`, `has:`, `hasnt:`)
  - Explicit non-pending status triggers global task list fallback (completed/deleted tasks visible)
  - Include/exclude tag and project sets with AND/OR match modes
  - Query autocomplete with inline suggestions for field names, values, operators
  - DUE operator respects forward-looking window (7 days)
  - Warnings on invalid date values; extracted date helper functions

- **Recurrence overhaul**
  - Recurrence limit moved from per-task UDA to worker-level config (0–5)
  - Guardrails: reject clearing recur on recurring tasks; block bulk completion of recurring templates and series
  - Series-vs-instance edit scoping in editor view and Rust-side validation
  - Parse named recurrence rules, shorthands (3w, 2mo), ISO periods (P6M, PT1H)
  - Reap exhausted recurring templates when until has passed with no pending/waiting children
  - Fix child-task wait-offset propagation
  - Migrate scheduled field writes from `sched` to `scheduled` for Taskwarrior compatibility

- **Custom storage location**
  - Choose custom storage directory via settings (preset folders + SAF folder picker)
  - Data-migration dialog (copy old data, delete old) when changing path
  - MANAGE_EXTERNAL_STORAGE permission for direct folder access (optional)
  - Profile name sanitization; auto-migrate legacy ID-based profile directories to name-based

### Fixed

- **Sync encryption secret**: stop trimming the encryption secret; preserve exact byte sequence for TaskChampion PBKDF2 input, preventing "error while unsealing encrypted value". Full Rust error source chain now exposed on sync failures.
- **Calendar errors surfaced**: remove PlatformException suppression in CalendarService; wrap each `_calendarService` call with try/catch so errors are shown to the user instead of silently swallowed.
- **Duplicate query parser**: eliminate the full Dart-side query parser (~950 lines) in favor of a lightweight heuristic scanner; delete task_filter_evaluator.dart (third redundant filter mechanism).
- **Sync isolate re-creation**: replace `compute()`-per-sync with a persistent background isolate, avoiding `RustLib.init()` and `TaskManager()` re-creation on every sync.
- **Query correctness**: fix date comparisons, `_tokenizeQuery` handling of escaped quotes, DUE forward-looking window alignment.
- **Duplicate loadProfile**: remove double-defined `loadProfile` function.
- **clearFilters** no longer resets the active context.

### Changed

- **TaskState god object decomposed** into seven focused services:
  - `TaskRepository` — CRUD, task lists, loadProfile, autocomplete, export/import
  - `TaskFilterService` — filter state, query building, cache, client-side matching
  - `TaskTabService` — filter tab CRUD, SharedPreferences persistence, legacy migration helpers
  - `TaskContextService` — context CRUD, SharedPreferences persistence
  - `TaskSelectionService` — selected task UUIDs, toggle/clear
  - `TaskQueueService` — queue view state (ready/waiting/scheduled), source task resolution
  - `SyncIsolateService` — persistent background isolate with SendPort/ReceivePort message loop
- TaskState reduced from ~1349 to ~600 lines; acts as coordinator delegating to services and calling `notifyListeners()` after mutation.

### Removed

- 9 no-op `#[frb]` attributes from API DTOs and impl blocks (closes #14)
- Full Dart query parser and evaluator (`task_filter_evaluator.dart`)
- `compute()`-per-sync pattern (replaced by persistent isolate)

### Testing

- Introduce Taskwarrior compatibility test suite in Rust (`compat` module) mapped from TW's Python test suite
- `TestContext` wrapper for CLI-like ergonomics; known gaps print info instead of failing
- Update CI workflow actions

[0.2.0]: https://github.com/anomalco/taskdroid/releases/tag/v0.2.0
[0.1.0]: https://github.com/anomalco/taskdroid/releases/tag/v0.1.0
