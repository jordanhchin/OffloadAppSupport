# AppSupport Offload

Current release: **0.2.0**

A lightweight, terminal-native macOS tool for moving large folders out of
`~/Library/Application Support` and onto an external disk. It keeps the path
apps expect by replacing the verified local folder with a symbolic link.

It is implemented in the Bash 3.2 already included with macOS—no Python,
package manager, framework, or background service is required. The interaction
model is inspired by tools such as [Mole](https://github.com/tw93/Mole): a small
scriptable CLI with a polished terminal interface.

## Features

- Folder inventory sorted by actual allocated size
- Installed-app audit with conservative orphaned-data recommendations
- Persistent, user-managed search locations for apps installed outside the
  standard macOS application folders
- Interactive external-disk selection with available space
- Offload and restore workflows
- Unified offload management: restore, verified cross-drive move, or permanent
  deletion
- Health and Repair Center for broken links, renamed or missing disks, stale
  staging copies, rollback data, and interrupted transactions
- Running-process protection using macOS `lsof`
- APFS / Mac OS Extended filesystem guard
- Metadata-preserving copies using macOS `ditto` (ACLs, xattrs, resource forks)
- SHA-256 manifests checked before and after every copy
- A final source re-hash to catch changes made during the transaction
- Atomic local-folder-to-symlink switch with automatic rollback on failure
- Real copy progress plus checksum and commit phases
- Window-aware layouts that use all available rows and resize on redraw
- An always-visible adaptive disk bar showing capacity, space consumed, and
  percent consumed for the local disk and mounted volumes
- Exit summary listing every action and the net local-space change
- Equivalent noninteractive commands for scripting

## Run it

```bash
./bin/appoffload
```

Or install it for the current user:

```bash
./install.sh
appoffload
```

The TUI uses arrow-key menus throughout. Choose **Offload**, select a folder,
select a mounted external disk, and confirm. Choose **Manage existing offloads**
to restore, move, or permanently delete a managed offload.

The bottom disk bar adapts to available space. Large windows display more
mounted disks across additional status rows. Smaller windows prioritize the
local disk and show `+N more`; below the minimum useful dimensions, the bar is
hidden so it does not cover menus or transaction messages. Disk figures refresh
during redraws and active transfer progress.

The CLI equivalents are:

```bash
appoffload list
appoffload audit
appoffload locations
appoffload locations add "/Volumes/External SSD/Applications"
appoffload locations remove "/Volumes/External SSD/Applications"
appoffload offload "Claude" --target "/Volumes/External SSD"
appoffload offloads
appoffload offloads restore "Claude"
appoffload offloads move "Claude" --target "/Volumes/Second SSD"
appoffload offloads delete "Claude" --yes
appoffload health
appoffload health repair "Claude"
appoffload restore "Claude"
```

### Health and Repair Center

Choose **Health and repair center** in the TUI, or run `appoffload health`, to
check every known offload plus transaction and recovery artifacts. AppSupport
Offload records each target disk's stable volume identity in
`~/.config/appoffload/offloads.tsv`; this lets it find the same disk after its
volume name or mount path changes.

The scanner distinguishes healthy links from unavailable disks, missing managed
data, local path conflicts, stale registry entries, incomplete staging copies,
interrupted transactions, and recoverable rollback folders. Only issues with a
bounded safe repair offer an action. Every mutation is confirmed in the TUI;
destructive or recovery-oriented CLI actions require `--yes`.

Link repair is atomic and does not move app data. Cleanup and recovery commands
are constrained to AppSupport Offload's managed paths. A real folder at the
expected local path is never overwritten, and final verified external data is
never automatically deleted by the Health Center.

### Managing offloads

The **Manage existing offloads** screen lists only links created by this tool.
After selecting one, choose:

- **Restore** — copy back to local staging, verify every file, activate the local
  folder, and then remove the external copy.
- **Move** — copy to another external disk, verify it, atomically retarget the
  managed symlink, and then remove the old external copy. Local disk usage does
  not change.
- **Permanently delete** — remove the external data and managed local link. The
  TUI requires typing `DELETE`; the CLI requires `--yes`. This cannot be undone.

### Installed-app audit

Choose **Compare installed apps** in the TUI, or run `appoffload audit`. The
scanner reads bundle identifiers and names from apps below `/Applications`,
`~/Applications`, and `/System/Applications`, then compares them with
Application Support folder names.

Results are classified as:

- **INSTALLED** — an exact bundle identifier or normalized app-name match.
- **RECOMMEND** — no installed match, a reverse-domain-style folder name, and
  surviving preference or saved-state evidence consistent with an uninstalled
  app. These are highlighted as offload candidates.
- **REVIEW** — no reliable match. The tool does not assume these are abandoned.
- **RELATED** — the folder belongs to the bundle-ID family of an installed app,
  such as a helper process.
- **SYSTEM** — an Apple-managed macOS component; never recommended.
- **OFFLOADED** — already managed by AppSupport Offload.

Application Support naming is not standardized, so the audit intentionally
prefers missed recommendations over falsely claiming live data is orphaned.

### Additional app locations

Choose **Manage installed-app search locations** in the TUI to list, add, or
remove folders that may contain `.app` bundles. Added locations are searched
recursively, so a folder can contain apps directly or inside subfolders.

Custom locations are saved in:

```text
~/.config/appoffload/app-roots
```

The three built-in locations cannot be removed:

```text
/Applications
~/Applications
/System/Applications
```

A custom path on an external disk remains configured while that disk is
unmounted. It is shown as `not mounted` and automatically participates in the
next audit after the disk returns. Managing search locations never changes or
moves anything inside those folders.

## Transaction safety

An offload proceeds in this order:

1. Confirm the source is a real folder, the target is writable and compatible,
   and the target has the folder size plus a safety margin available.
2. Refuse to continue if `lsof` finds a process with files open below the
   selected folder.
3. Copy into a uniquely named staging directory with `ditto`.
4. Build and compare SHA-256 manifests for every regular file, directory, and
   symbolic link, then hash the source once more to detect concurrent changes.
5. Re-run the open-file check.
6. Rename the verified staging copy into place, rename the local source to a
   hidden rollback path, and create and validate the symbolic link.
7. Only then remove the local rollback copy and report reclaimed space.

Restore performs the reverse: copy external data to local staging, fully verify
it, replace the managed link with the local folder, and only then remove the
external copy. `Ctrl-C` and termination signals stop an active copy and restore
the local source when a switch was in progress.

Transaction state is also written below
`/Volumes/<disk>/.AppSupportOffload/.transactions/` for diagnosis after an
unexpected power loss.

## Why symbolic links?

For per-user Application Support data, a symlink is the most transparent option:
it needs no privileged daemon, custom filesystem, or persistent mount rule, and
is easy to inspect and reverse. macOS has no general-purpose bind-mount facility,
while mounting a separate APFS volume at each app folder would be considerably
more operationally fragile.

Use an **APFS-formatted SSD** whenever possible. The tool rejects filesystems
such as exFAT because they cannot faithfully preserve all macOS metadata.

## Important limitations

- Quit the app before moving or restoring its data. The tool checks open files
  twice, but cannot prevent you or another service from launching the app at the
  exact commit instant.
- Keep the external disk mounted whenever using an offloaded app. A missing disk
  leaves a safe but unavailable (dangling) link; it does not silently fall back
  to a new local folder.
- Some sandboxed or security-sensitive apps reject data reached through an
  external symlink. If an app behaves that way, quit it and use **Restore**.
- This is not a backup. Keep a separate current backup of both disks.

## Development checks

```bash
./scripts/check.sh
```

The test suite performs complete temporary offload, restore, and cross-drive
transactions; checks file content and extended attributes; exercises target-disk
rename and link repair, interrupted-transaction recovery, cleanup path guards,
process protection, and destination conflicts. It never operates on the real
Application Support folder.
