# Changelog

## 0.2.0 — 2026-08-30

- Add an interactive Health and Repair Center and matching scriptable commands.
- Track offloads by stable target-volume identity so links can be repaired after
  a disk is renamed or remounted at a different path.
- Detect healthy offloads, unavailable disks, missing data, stale records,
  path conflicts, abandoned staging copies, interrupted transactions, and
  recoverable local rollback copies.
- Add guarded repairs for managed links, stale staging data, interrupted
  transactions, and rollback copies. Repairs never overwrite a real local
  folder or automatically delete a verified final data copy.

## 0.1.0 — 2026-08-30

- Initial release with the adaptive arrow-key TUI, disk status bar, app audit,
  persistent application search locations, verified offload/restore/move/delete
  transactions, process protection, and exit space summary.
