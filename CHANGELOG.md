# Changelog

## 0.4.2 — 2026-09-24

- Clean failed local restore copies and surface abandoned restore staging in the
  health center.
- Journal restore and delete operations, record the old destination during
  moves, and recover interrupted copy and cleanup phases safely.
- Mark clean rollbacks as aborted and remove verified orphan copies after an
  interrupted offload. Show untracked managed copies and uncataloged network
  bundles in the health center for manual review.
- Report app lookup, missing health records, lock contention, and unreadable
  folder sizes accurately; accept trailing slashes on `.app` paths and make
  Escape work in the TUI.
- Retain a completed network sparsebundle when unmount fails and check free
  space before moving a backup to a network destination.

## 0.4.1 — 2026-09-24

- Show `OFFLOADED <size>` beside apps with managed Application Support data in
  the migration-backup picker and sort those apps first.

## 0.4.0 — 2026-09-24

- Add first-class SMB and NFS destinations for complete-app migration backups.
  Network backups use an APFS sparsebundle while native removable disks retain
  the existing `.appbackup` folder format.
- Keep network filesystems prohibited for live symlink offloads.
- Add unified migration-backup management: verify, restore, move between native
  and network destinations with format conversion, and permanently remove.
- Verify every moved backup before removing its source and retain readable
  sidecar catalog metadata beside network sparsebundles.

## 0.3.0 — 2026-09-24

- Add portable, non-destructive complete-app migration backups for moving to a
  new Mac.
- Discover and package the `.app` bundle plus conservatively associated user
  Library data, including Application Support, containers, group containers,
  preferences, caches, saved state, scripts, web/HTTP storage, cookies, logs,
  and matching launch agents.
- Materialize managed Application Support offloads into the backup so an app
  already offloaded by this tool restores as normal local data on the new Mac.
- Add self-contained metadata and SHA-256 manifests, standalone verification,
  guarded transactional restore, collision refusal, and TUI/CLI workflows.

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
