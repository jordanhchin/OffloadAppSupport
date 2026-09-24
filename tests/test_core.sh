#!/bin/bash

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
TEST_ROOT=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/appoffload-tests.XXXXXX")
trap '/bin/rm -rf "$TEST_ROOT"' EXIT

export APPOFFLOAD_APP_SUPPORT_ROOT="$TEST_ROOT/Library/Application Support"
export APPOFFLOAD_VOLUMES_ROOT="$TEST_ROOT/Volumes"
export APPOFFLOAD_APPLICATION_ROOTS="$TEST_ROOT/Applications"
export APPOFFLOAD_CONFIG_DIR="$TEST_ROOT/config"
export APPOFFLOAD_PREFERENCES_ROOT="$TEST_ROOT/Library/Preferences"
export APPOFFLOAD_SAVED_STATE_ROOT="$TEST_ROOT/Library/Saved Application State"
export APPOFFLOAD_USER_LIBRARY_ROOT="$TEST_ROOT/Library"
export APPOFFLOAD_USER_APPLICATIONS_ROOT="$TEST_ROOT/User Applications"
export APPOFFLOAD_ALLOW_ANY_TARGET=1
mkdir -p "$APPOFFLOAD_APP_SUPPORT_ROOT" "$APPOFFLOAD_VOLUMES_ROOT/External" "$APPOFFLOAD_VOLUMES_ROOT/External2" \
    "$APPOFFLOAD_APPLICATION_ROOTS" "$APPOFFLOAD_PREFERENCES_ROOT" "$APPOFFLOAD_SAVED_STATE_ROOT"

# shellcheck source=../lib/core.sh
. "$ROOT/lib/core.sh"
# shellcheck source=../lib/migration.sh
. "$ROOT/lib/migration.sh"

ui_progress() { :; }
fail() { echo "FAIL: $1" >&2; exit 1; }
assert_file() { [ -f "$1" ] || fail "expected file: $1"; }
assert_dir() { [ -d "$1" ] && [ ! -L "$1" ] || fail "expected directory: $1"; }
assert_link() { [ -L "$1" ] || fail "expected symlink: $1"; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "expected '$1' to contain '$2'" ;; esac; }

SOURCE="$APP_SUPPORT_ROOT/Example App"
TARGET="$APPOFFLOAD_VOLUMES_ROOT/External"
TARGET2="$APPOFFLOAD_VOLUMES_ROOT/External2"
mkdir -p "$SOURCE/empty" "$SOURCE/nested folder"
printf 'important application state\n' > "$SOURCE/settings.json"
printf 'content with spaces\n' > "$SOURCE/nested folder/data file.txt"
ln -s "../settings.json" "$SOURCE/nested folder/settings-link"
/usr/bin/xattr -w com.example.appoffload-test "preserved" "$SOURCE/settings.json"

offload_folder "$SOURCE" "$TARGET" || fail "$APPOFFLOAD_ERROR"
assert_link "$SOURCE"
DESTINATION=$(managed_link_destination "$SOURCE") || fail "managed link not recognized"
assert_file "$DESTINATION/settings.json"
[ "$(cat "$SOURCE/settings.json")" = "important application state" ] || fail "linked data mismatch"
[ "$(/usr/bin/xattr -p com.example.appoffload-test "$DESTINATION/settings.json")" = "preserved" ] || fail "extended attribute not preserved"
[ "$LAST_LOCAL_DELTA_BYTES" -gt 0 ] || fail "offload did not report saved bytes"

move_offload "$SOURCE" "$TARGET2" || fail "$APPOFFLOAD_ERROR"
MOVED_DESTINATION=$(managed_link_destination "$SOURCE") || fail "moved managed link not recognized"
[ "$MOVED_DESTINATION" != "$DESTINATION" ] || fail "move did not retarget managed link"
[ ! -e "$DESTINATION" ] || fail "old external copy retained after successful move"
assert_file "$MOVED_DESTINATION/settings.json"
[ "$(/usr/bin/xattr -p com.example.appoffload-test "$MOVED_DESTINATION/settings.json")" = "preserved" ] || fail "move did not preserve extended attribute"
[ "$LAST_LOCAL_DELTA_BYTES" -eq 0 ] || fail "external move incorrectly reported local disk change"
[ "$LAST_EXTERNAL_BYTES" -gt 0 ] || fail "external move did not report transferred bytes"

# A failed verification must remove the full local restore copy and close its journal.
ORIGINAL_VERIFY_TREES=$(declare -f verify_trees)
verify_trees() { APPOFFLOAD_ERROR="Injected verification failure"; return 1; }
if restore_folder "$SOURCE"; then fail "injected restore verification failure was accepted"; fi
eval "$ORIGINAL_VERIFY_TREES"
assert_link "$SOURCE"
for RESTORE_STAGE in "$APP_SUPPORT_ROOT"/."$(basename "$SOURCE")".appoffload-restore-*; do
    [ ! -e "$RESTORE_STAGE" ] || fail "failed restore retained a full local staging copy"
done
if health_scan | /usr/bin/awk -F '\t' '$2 == "incomplete-transaction" {found=1} END {exit !found}'; then
    fail "cleanly rolled-back restore was reported as incomplete"
fi
if path_bytes "$TEST_ROOT/no-such-folder" >/dev/null; then fail "unmeasurable folder was treated as zero bytes"; fi
PARTLY_UNREADABLE="$TEST_ROOT/Partly Unreadable"
mkdir -p "$PARTLY_UNREADABLE/restricted"
printf 'readable data\n' > "$PARTLY_UNREADABLE/readable"
printf 'private data\n' > "$PARTLY_UNREADABLE/restricted/private"
chmod 000 "$PARTLY_UNREADABLE/restricted"
if [ "$(/usr/bin/id -u)" -ne 0 ] && /usr/bin/du -sk "$PARTLY_UNREADABLE" >/dev/null 2>&1; then
    fail "unreadable-folder fixture did not make du report an error"
fi
PARTIAL_SIZE=$(path_bytes "$PARTLY_UNREADABLE") || fail "du subtotal was rejected for a partially unreadable folder"
[ "$PARTIAL_SIZE" -gt 0 ] || fail "du subtotal was not numeric"
chmod 700 "$PARTLY_UNREADABLE/restricted"

restore_folder "$SOURCE" || fail "$APPOFFLOAD_ERROR"
assert_dir "$SOURCE"
assert_file "$SOURCE/nested folder/data file.txt"
[ ! -e "$MOVED_DESTINATION" ] || fail "external copy retained after successful restore"
[ "$LAST_LOCAL_DELTA_BYTES" -lt 0 ] || fail "restore did not report consumed bytes"

FAILED_OFFLOAD_SOURCE="$APP_SUPPORT_ROOT/Failed Offload"
mkdir -p "$FAILED_OFFLOAD_SOURCE"
printf 'original stays local\n' > "$FAILED_OFFLOAD_SOURCE/state"
ORIGINAL_VERIFY_TREES=$(declare -f verify_trees)
verify_trees() { APPOFFLOAD_ERROR="Injected offload verification failure"; return 1; }
if offload_folder "$FAILED_OFFLOAD_SOURCE" "$TARGET"; then fail "injected offload verification failure was accepted"; fi
eval "$ORIGINAL_VERIFY_TREES"
assert_dir "$FAILED_OFFLOAD_SOURCE"
[ ! -e "$TARGET/$MANAGED_DIR_NAME/${USER:-$(id -un)}/Application Support/Failed Offload" ] || fail "failed offload left an external copy"
if health_scan | /usr/bin/awk -F '\t' '$2 == "incomplete-transaction" {found=1} END {exit !found}'; then
    fail "cleanly rolled-back offload was reported as incomplete"
fi

# Permanent deletion removes both the managed link and external data.
DELETE_SOURCE="$APP_SUPPORT_ROOT/Delete Me"
mkdir -p "$DELETE_SOURCE"
printf 'disposable offload\n' > "$DELETE_SOURCE/data.bin"
offload_folder "$DELETE_SOURCE" "$TARGET" || fail "$APPOFFLOAD_ERROR"
DELETE_DESTINATION=$(managed_link_destination "$DELETE_SOURCE") || fail "delete fixture link not recognized"
delete_offload "$DELETE_SOURCE" || fail "$APPOFFLOAD_ERROR"
[ ! -e "$DELETE_SOURCE" ] && [ ! -L "$DELETE_SOURCE" ] || fail "managed link retained after deletion"
[ ! -e "$DELETE_DESTINATION" ] || fail "external data retained after deletion"
[ "$LAST_EXTERNAL_BYTES" -gt 0 ] || fail "deletion did not report removed bytes"

# A process guard refusal must leave source and target unchanged.
GUARDED="$APP_SUPPORT_ROOT/Guarded App"
mkdir -p "$GUARDED"
printf 'busy\n' > "$GUARDED/state.db"
FAKE_LSOF="$TEST_ROOT/fake-lsof"
cat > "$FAKE_LSOF" <<'MOCK'
#!/bin/bash
printf 'p4242\ncExampleApp\n'
MOCK
chmod +x "$FAKE_LSOF"
export APPOFFLOAD_LSOF="$FAKE_LSOF"
if offload_folder "$GUARDED" "$TARGET"; then fail "process guard allowed an in-use folder"; fi
assert_contains "$APPOFFLOAD_ERROR" "ExampleApp"
assert_dir "$GUARDED"
unset APPOFFLOAD_LSOF

# Existing external data must never be overwritten.
CONFLICT="$APP_SUPPORT_ROOT/Conflict App"
mkdir -p "$CONFLICT"
mkdir -p "$TARGET/$MANAGED_DIR_NAME/${USER:-$(id -un)}/Application Support/Conflict App"
if offload_folder "$CONFLICT" "$TARGET"; then fail "destination conflict was overwritten"; fi
assert_contains "$APPOFFLOAD_ERROR" "already exists"
assert_dir "$CONFLICT"

# Lexical prefix tricks must not escape Application Support.
OUTSIDE="$TEST_ROOT/Library/Outside App"
mkdir -p "$OUTSIDE"
if offload_folder "$APP_SUPPORT_ROOT/../Outside App" "$TARGET"; then fail "path traversal escaped Application Support"; fi
assert_contains "$APPOFFLOAD_ERROR" "immediate child"
assert_dir "$OUTSIDE"

# Installed-app comparison: exact bundle IDs match, evidence-backed missing IDs
# are recommended, and ambiguous names remain review-only.
FAKE_APP="$APPOFFLOAD_APPLICATION_ROOTS/Installed.app"
mkdir -p "$FAKE_APP/Contents" "$APP_SUPPORT_ROOT/com.example.Installed" \
    "$APP_SUPPORT_ROOT/com.example.Orphaned" "$APP_SUPPORT_ROOT/Vendor Data"
cat > "$FAKE_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.example.Installed</string>
<key>CFBundleName</key><string>Installed</string>
<key>CFBundleExecutable</key><string>Installed</string>
</dict></plist>
PLIST
touch "$APPOFFLOAD_PREFERENCES_ROOT/com.example.Orphaned.plist"
printf 'orphaned state\n' > "$APP_SUPPORT_ROOT/com.example.Orphaned/state.dat"
AUDIT_REPORT="$TEST_ROOT/audit.tsv"
audit_folders > "$AUDIT_REPORT" || fail "app audit failed"
/usr/bin/awk -F '\t' -v p="$APP_SUPPORT_ROOT/com.example.Installed" '$2 == "installed" && $4 == p {found=1} END {exit !found}' "$AUDIT_REPORT" || fail "installed bundle ID was not matched"
/usr/bin/awk -F '\t' -v p="$APP_SUPPORT_ROOT/com.example.Orphaned" '$2 == "recommend" && $4 == p {found=1} END {exit !found}' "$AUDIT_REPORT" || fail "orphan candidate was not recommended"
/usr/bin/awk -F '\t' -v p="$APP_SUPPORT_ROOT/Vendor Data" '$2 == "review" && $4 == p {found=1} END {exit !found}' "$AUDIT_REPORT" || fail "ambiguous folder was over-classified"

# Custom application roots are persisted, affect the audit, survive being
# temporarily unavailable, and can be removed without touching their contents.
EXTRA_ROOT="$TEST_ROOT/Extra App Shelf"
EXTRA_APP="$EXTRA_ROOT/Utilities/External Tool.app"
EXTRA_SUPPORT="$APP_SUPPORT_ROOT/org.example.ExternalTool"
mkdir -p "$EXTRA_APP/Contents" "$EXTRA_SUPPORT"
cat > "$EXTRA_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.example.ExternalTool</string>
<key>CFBundleName</key><string>External Tool</string>
</dict></plist>
PLIST
SAVED_ROOT=$(add_app_root "$EXTRA_ROOT") || fail "$APPOFFLOAD_ERROR"
[ "$SAVED_ROOT" = "$(cd "$EXTRA_ROOT" && pwd -P)" ] || fail "custom app root was not canonicalized as expected"
[ -f "$APP_ROOTS_FILE" ] || fail "custom app root was not persisted"
audit_folders > "$AUDIT_REPORT" || fail "audit with custom root failed"
/usr/bin/awk -F '\t' -v p="$EXTRA_SUPPORT" '$2 == "installed" && $4 == p {found=1} END {exit !found}' "$AUDIT_REPORT" || fail "persisted custom root did not affect audit"
mv "$SAVED_ROOT" "$TEST_ROOT/Temporarily Unmounted"
list_app_roots | /usr/bin/awk -F '\t' -v p="$SAVED_ROOT" '$1 == "custom" && $2 == "unavailable" && $3 == p {found=1} END {exit !found}' || fail "unmounted custom root was not retained"
remove_app_root "$SAVED_ROOT" || fail "$APPOFFLOAD_ERROR"
custom_app_roots | /usr/bin/awk -v p="$SAVED_ROOT" '$0 == p {found=1} END {exit found}' || fail "custom root was not removed"
[ -d "$TEST_ROOT/Temporarily Unmounted" ] || fail "removing search location changed app files"

# Complete-app migration materializes an existing managed offload into a
# portable backup, includes other associated Library data, verifies the package,
# and restores into a clean simulated new Mac without overwriting collisions.
MIGRATION_APP="$APPOFFLOAD_APPLICATION_ROOTS/Migrator.app"
MIGRATION_SUPPORT="$APP_SUPPORT_ROOT/com.example.Migrator"
MIGRATION_PREF="$APPOFFLOAD_USER_LIBRARY_ROOT/Preferences/com.example.Migrator.plist"
MIGRATION_CONTAINER="$APPOFFLOAD_USER_LIBRARY_ROOT/Containers/com.example.Migrator"
mkdir -p "$MIGRATION_APP/Contents" "$MIGRATION_SUPPORT" "$MIGRATION_CONTAINER"
cat > "$MIGRATION_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.example.Migrator</string>
<key>CFBundleName</key><string>Migrator</string>
<key>CFBundleShortVersionString</key><string>4.2</string>
</dict></plist>
PLIST
printf 'app executable payload\n' > "$MIGRATION_APP/Contents/MacOS-data"
printf 'offloaded user state\n' > "$MIGRATION_SUPPORT/state.db"
printf 'preference data\n' > "$MIGRATION_PREF"
printf 'sandbox data\n' > "$MIGRATION_CONTAINER/container.db"
offload_folder "$MIGRATION_SUPPORT" "$TARGET" || fail "$APPOFFLOAD_ERROR"
MIGRATION_EXTERNAL=$(managed_link_destination "$MIGRATION_SUPPORT") || fail "migration fixture was not offloaded"
resolve_migratable_app "$MIGRATION_APP/" >/dev/null || fail "app path with trailing slash was rejected"
[ "$RESOLVED_MIGRATABLE_APP" = "$(cd "$MIGRATION_APP" && pwd -P)" ] || fail "trailing-slash app resolved incorrectly"
LOOKUP_ERROR=$("$ROOT/bin/appoffload" app inspect NoSuchInstalledApp 2>&1) && fail "missing app lookup succeeded"
assert_contains "$LOOKUP_ERROR" "No installed app matches: NoSuchInstalledApp"
MIGRATION_OFFLOAD_REPORT="$TEST_ROOT/migration-offloads.tsv"
list_managed_migration_offloads > "$MIGRATION_OFFLOAD_REPORT"
/usr/bin/awk -F '\t' '$1 > 0 && $2 == "com.example.Migrator" {found=1} END {exit !found}' "$MIGRATION_OFFLOAD_REPORT" || fail "managed migration offload was not indexed"
IFS=$'\t' read -r MIGRATION_OFFLOAD_COUNT MIGRATION_OFFLOAD_BYTES <<< "$(migration_offload_totals "Migrator" "com.example.Migrator" "$MIGRATION_OFFLOAD_REPORT")"
[ "$MIGRATION_OFFLOAD_COUNT" -eq 1 ] || fail "migration picker did not associate the managed offload with its app"
[ "$MIGRATION_OFFLOAD_BYTES" -gt 0 ] || fail "migration picker did not report managed offload size"
IFS=$'\t' read -r OTHER_OFFLOAD_COUNT OTHER_OFFLOAD_BYTES <<< "$(migration_offload_totals "Other" "com.example.Other" "$MIGRATION_OFFLOAD_REPORT")"
[ "$OTHER_OFFLOAD_COUNT" -eq 0 ] && [ "$OTHER_OFFLOAD_BYTES" -eq 0 ] || fail "migration picker associated an unrelated offload"
create_app_migration_backup "$MIGRATION_APP" "$TARGET2" || fail "$APPOFFLOAD_ERROR"
MIGRATION_BACKUP="$LAST_MIGRATION_BACKUP"
[ "$LAST_MIGRATION_OFFLOADED_COUNT" -eq 1 ] || fail "migration did not report materializing the managed offload"
[ -d "$MIGRATION_BACKUP" ] || fail "migration backup was not committed"
verify_app_migration_backup "$MIGRATION_BACKUP" || fail "$APPOFFLOAD_ERROR"
assert_file "$MIGRATION_BACKUP/payload/Library/Application Support/com.example.Migrator/state.db"
[ ! -L "$MIGRATION_BACKUP/payload/Library/Application Support/com.example.Migrator" ] || fail "migration backup preserved the offload symlink instead of its data"
assert_file "$MIGRATION_EXTERNAL/state.db"
assert_link "$MIGRATION_SUPPORT"

NEW_LIBRARY="$TEST_ROOT/New Mac/Library"
NEW_APPS="$TEST_ROOT/New Mac/Applications"
mkdir -p "$NEW_LIBRARY" "$NEW_APPS"
USER_LIBRARY_ROOT="$NEW_LIBRARY"
USER_APPLICATIONS_ROOT="$NEW_APPS"
restore_app_migration_backup "$MIGRATION_BACKUP" "$NEW_APPS" || fail "$APPOFFLOAD_ERROR"
assert_dir "$NEW_APPS/Migrator.app"
assert_dir "$NEW_LIBRARY/Application Support/com.example.Migrator"
assert_file "$NEW_LIBRARY/Application Support/com.example.Migrator/state.db"
assert_file "$NEW_LIBRARY/Preferences/com.example.Migrator.plist"
assert_file "$NEW_LIBRARY/Containers/com.example.Migrator/container.db"
if restore_app_migration_backup "$MIGRATION_BACKUP" "$NEW_APPS"; then fail "migration restore overwrote existing data"; fi
assert_contains "$APPOFFLOAD_ERROR" "refused to overwrite"

# SMB/NFS migration destinations use a sparsebundle transport. Exercise
# creation, discovery, verification, conversion back to a native folder backup,
# a move back to the network, and permanent removal with a deterministic hdiutil
# stand-in (the real hdiutil is covered by macOS integration smoke checks).
NETWORK_TARGET="$APPOFFLOAD_VOLUMES_ROOT/SMB Share"
FAKE_HDIUTIL="$TEST_ROOT/fake-hdiutil"
mkdir -p "$NETWORK_TARGET"
printf 'smbfs\n' > "$NETWORK_TARGET/.appoffload-filesystem-personality"
ORIGINAL_FILESYSTEM_PERSONALITY=$(declare -f filesystem_personality)
filesystem_personality() { printf 'SMBFS\n'; }
APPOFFLOAD_ALLOW_ANY_TARGET=0
if ensure_compatible_filesystem "$NETWORK_TARGET"; then fail "live offload filesystem guard accepted SMBFS"; fi
assert_contains "$APPOFFLOAD_ERROR" "Unsupported target filesystem"
eval "$ORIGINAL_FILESYSTEM_PERSONALITY"
APPOFFLOAD_ALLOW_ANY_TARGET=1
cat > "$FAKE_HDIUTIL" <<'MOCK'
#!/bin/bash
command="$1"
last=""
for argument in "$@"; do last="$argument"; done
case "$command" in
    create) mkdir -p "$last/mount" ;;
    attach) printf '/dev/disk-test\tApple_APFS\t%s\n' "$last/mount" ;;
    detach) [ "${APPOFFLOAD_FAKE_DETACH_FAIL:-0}" != "1" ] ;;
    *) exit 2 ;;
esac
MOCK
chmod +x "$FAKE_HDIUTIL"
HDIUTIL_BIN="$FAKE_HDIUTIL"
create_app_migration_backup "$MIGRATION_APP" "$NETWORK_TARGET" || fail "$APPOFFLOAD_ERROR"
NETWORK_BACKUP="$LAST_MIGRATION_BACKUP"
case "$NETWORK_BACKUP" in *.appmigration.sparsebundle) ;; *) fail "network migration did not create a sparsebundle" ;; esac
assert_file "$NETWORK_BACKUP.appoffload.conf"
verify_app_migration_source "$NETWORK_BACKUP" || fail "$APPOFFLOAD_ERROR"
list_app_migration_backups | /usr/bin/awk -F '\t' -v p="$NETWORK_BACKUP" '$5 == p {found=1} END {exit !found}' || fail "network migration was not listed"
move_app_migration_backup "$NETWORK_BACKUP" "$TARGET" || fail "$APPOFFLOAD_ERROR"
NATIVE_MOVED_BACKUP="$LAST_MIGRATION_BACKUP"
case "$NATIVE_MOVED_BACKUP" in *.appbackup) ;; *) fail "network-to-native move did not extract the appbackup" ;; esac
[ ! -e "$NETWORK_BACKUP" ] || fail "network source remained after verified move"
verify_app_migration_source "$NATIVE_MOVED_BACKUP" || fail "$APPOFFLOAD_ERROR"
move_app_migration_backup "$NATIVE_MOVED_BACKUP" "$NETWORK_TARGET" || fail "$APPOFFLOAD_ERROR"
NETWORK_MOVED_BACKUP="$LAST_MIGRATION_BACKUP"
case "$NETWORK_MOVED_BACKUP" in *.appmigration.sparsebundle) ;; *) fail "native-to-network move did not create a sparsebundle" ;; esac
[ ! -e "$NATIVE_MOVED_BACKUP" ] || fail "native source remained after verified network move"
delete_app_migration_backup "$NETWORK_MOVED_BACKUP" || fail "$APPOFFLOAD_ERROR"
[ ! -e "$NETWORK_MOVED_BACKUP" ] && [ ! -e "$NETWORK_MOVED_BACKUP.appoffload.conf" ] || fail "network backup removal left managed files"

ORIGINAL_AVAILABLE_BYTES=$(declare -f available_bytes)
available_bytes() { printf '0\n'; }
if move_app_migration_backup "$MIGRATION_BACKUP" "$NETWORK_TARGET"; then fail "network move ignored insufficient target space"; fi
assert_contains "$APPOFFLOAD_ERROR" "Not enough network space"
eval "$ORIGINAL_AVAILABLE_BYTES"

export APPOFFLOAD_FAKE_DETACH_FAIL=1
if move_app_migration_backup "$MIGRATION_BACKUP" "$NETWORK_TARGET"; then fail "failed sparsebundle detach was accepted"; fi
assert_contains "$APPOFFLOAD_ERROR" "retained at"
assert_dir "$MIGRATION_BACKUP"
RETAINED_BUNDLE=$(/usr/bin/find "$NETWORK_TARGET" -name '*.appmigration.sparsebundle' -type d -print -quit)
[ -n "$RETAINED_BUNDLE" ] || fail "failed unmount discarded the completed sparsebundle"
health_scan > "$TEST_ROOT/network-health.tsv"
/usr/bin/awk -F '\t' -v p="$RETAINED_BUNDLE" '$2 == "uncataloged-backup" && $4 == p {found=1} END {exit !found}' "$TEST_ROOT/network-health.tsv" || fail "retained sparsebundle was not visible in health scan"
rollback_active_transaction
[ -d "$RETAINED_BUNDLE" ] || fail "later rollback deleted a retained sparsebundle"
unset APPOFFLOAD_FAKE_DETACH_FAIL

printf 'tamper\n' >> "$MIGRATION_BACKUP/payload/Library/Application Support/com.example.Migrator/state.db"
if verify_app_migration_backup "$MIGRATION_BACKUP"; then fail "migration verification accepted modified payload data"; fi
assert_contains "$APPOFFLOAD_ERROR" "checksum verification failed"
delete_app_migration_backup "$MIGRATION_BACKUP" || fail "corrupt migration backup could not be explicitly removed: $APPOFFLOAD_ERROR"
[ ! -e "$MIGRATION_BACKUP" ] || fail "explicit removal retained the corrupt migration backup"
USER_LIBRARY_ROOT="$APPOFFLOAD_USER_LIBRARY_ROOT"
USER_APPLICATIONS_ROOT="$APPOFFLOAD_USER_APPLICATIONS_ROOT"

# Health center: persist identity, detect a renamed target volume, repair both a
# dangling and a missing link, clean staging, and recover interrupted rollback.
HEALTH_OLD="$APPOFFLOAD_VOLUMES_ROOT/HealthOld"
HEALTH_NEW="$APPOFFLOAD_VOLUMES_ROOT/HealthRenamed"
HEALTH_SOURCE="$APP_SUPPORT_ROOT/Health App"
mkdir -p "$HEALTH_OLD" "$HEALTH_SOURCE"
printf 'health-volume-id\n' > "$HEALTH_OLD/.appoffload-volume-id"
printf 'healthy data\n' > "$HEALTH_SOURCE/state.db"
offload_folder "$HEALTH_SOURCE" "$HEALTH_OLD" || fail "$APPOFFLOAD_ERROR"
lookup_offload_record "$HEALTH_SOURCE" || fail "offload registry record was not created"
if remove_offload_record "$APP_SUPPORT_ROOT/Not Registered"; then fail "forgetting an unknown health record reported success"; fi
assert_contains "$APPOFFLOAD_ERROR" "No health record exists"
HEALTH_REPORT="$TEST_ROOT/health.tsv"
health_scan > "$HEALTH_REPORT"
/usr/bin/awk -F '\t' -v p="$HEALTH_SOURCE" '$2 == "healthy" && $4 == p {found=1} END {exit !found}' "$HEALTH_REPORT" || fail "healthy offload was not reported"

mv "$HEALTH_OLD" "$HEALTH_NEW"
health_scan > "$HEALTH_REPORT"
/usr/bin/awk -F '\t' -v p="$HEALTH_SOURCE" '$2 == "repairable-link" && $4 == p && $7 == "repair-link" {found=1} END {exit !found}' "$HEALTH_REPORT" || fail "renamed-volume link was not repairable"
repair_offload_link "$HEALTH_SOURCE" || fail "$APPOFFLOAD_ERROR"
HEALTH_NEW_PHYSICAL=$(cd "$HEALTH_NEW" && pwd -P)
case "$(readlink "$HEALTH_SOURCE")" in "$HEALTH_NEW_PHYSICAL"/*) ;; *) fail "health repair did not retarget renamed volume" ;; esac

unlink "$HEALTH_SOURCE"
health_scan > "$HEALTH_REPORT"
/usr/bin/awk -F '\t' -v p="$HEALTH_SOURCE" '$2 == "repairable-link" && $4 == p {found=1} END {exit !found}' "$HEALTH_REPORT" || fail "missing managed link was not detected"
repair_offload_link "$HEALTH_SOURCE" || fail "$APPOFFLOAD_ERROR"
assert_link "$HEALTH_SOURCE"

unlink "$HEALTH_SOURCE"
mkdir "$HEALTH_SOURCE"
health_scan > "$HEALTH_REPORT"
/usr/bin/awk -F '\t' -v p="$HEALTH_SOURCE" '$2 == "stale-record" && $4 == p {found=1} END {exit !found}' "$HEALTH_REPORT" || fail "local path conflict was not reported"
if repair_offload_link "$HEALTH_SOURCE"; then fail "health repair overwrote a real local folder"; fi
rmdir "$HEALTH_SOURCE"
repair_offload_link "$HEALTH_SOURCE" || fail "$APPOFFLOAD_ERROR"

STALE_STAGE="$HEALTH_NEW/$MANAGED_DIR_NAME/${USER:-$(id -un)}/Application Support/.appoffload-staging-test"
mkdir -p "$STALE_STAGE"
printf 'partial\n' > "$STALE_STAGE/partial"
health_scan > "$HEALTH_REPORT"
/usr/bin/awk -F '\t' -v p="$STALE_STAGE" '$2 == "stale-staging" && $4 == p {found=1} END {exit !found}' "$HEALTH_REPORT" || fail "stale staging was not detected"
clean_health_staging "$STALE_STAGE" || fail "$APPOFFLOAD_ERROR"
[ ! -e "$STALE_STAGE" ] || fail "stale staging was not removed"

STALE_LOCAL_RESTORE="$APP_SUPPORT_ROOT/.Stale Local.appoffload-restore-test"
mkdir -p "$STALE_LOCAL_RESTORE"
printf 'incomplete copy\n' > "$STALE_LOCAL_RESTORE/partial"
health_scan > "$HEALTH_REPORT"
/usr/bin/awk -F '\t' -v p="$STALE_LOCAL_RESTORE" '$2 == "stale-staging" && $4 == p {found=1} END {exit !found}' "$HEALTH_REPORT" || fail "local restore staging was not detected"
clean_health_staging "$STALE_LOCAL_RESTORE" || fail "$APPOFFLOAD_ERROR"
[ ! -e "$STALE_LOCAL_RESTORE" ] || fail "local restore staging was not removed"

TXN_SOURCE="$APP_SUPPORT_ROOT/Interrupted App"
TXN_BACKUP="$APP_SUPPORT_ROOT/.Interrupted App.appoffload-backup-test"
TXN_STAGE="$HEALTH_NEW/$MANAGED_DIR_NAME/${USER:-$(id -un)}/Application Support/.appoffload-staging-transaction"
TXN_JOURNAL="$HEALTH_NEW/$MANAGED_DIR_NAME/.transactions/interrupted.state"
mkdir -p "$TXN_BACKUP" "$TXN_STAGE" "$(dirname "$TXN_JOURNAL")"
printf 'rollback data\n' > "$TXN_BACKUP/state"
{
    printf 'version=1\nphase=source-moved\n'
    printf 'source=%s\n' "$(encode_field "$TXN_SOURCE")"
    printf 'backup=%s\n' "$(encode_field "$TXN_BACKUP")"
    printf 'stage=%s\n' "$(encode_field "$TXN_STAGE")"
    printf 'final=%s\n' "$(encode_field "")"
} > "$TXN_JOURNAL"
health_scan > "$HEALTH_REPORT"
/usr/bin/awk -F '\t' -v p="$TXN_JOURNAL" '$2 == "incomplete-transaction" && $4 == p {found=1} END {exit !found}' "$HEALTH_REPORT" || fail "interrupted transaction was not detected"
recover_incomplete_transaction "$TXN_JOURNAL" || fail "$APPOFFLOAD_ERROR"
assert_dir "$TXN_SOURCE"
[ ! -e "$TXN_STAGE" ] || fail "transaction staging remained after recovery"
[ "$(/usr/bin/awk -F= '$1 == "phase" {print $2}' "$TXN_JOURNAL")" = "recovered" ] || fail "transaction was not marked recovered"

MOVE_REPAIR_SOURCE="$APP_SUPPORT_ROOT/Interrupted Move"
MOVE_REPAIR_OLD="$TARGET/$MANAGED_DIR_NAME/${USER:-$(id -un)}/Application Support/Interrupted Move"
MOVE_REPAIR_NEW="$TARGET2/$MANAGED_DIR_NAME/${USER:-$(id -un)}/Application Support/Interrupted Move"
MOVE_REPAIR_JOURNAL="$TARGET2/$MANAGED_DIR_NAME/.transactions/interrupted-move.state"
mkdir -p "$MOVE_REPAIR_OLD" "$MOVE_REPAIR_NEW" "$(dirname "$MOVE_REPAIR_JOURNAL")"
printf 'same data\n' > "$MOVE_REPAIR_OLD/state"
printf 'same data\n' > "$MOVE_REPAIR_NEW/state"
ln -s "$MOVE_REPAIR_NEW" "$MOVE_REPAIR_SOURCE"
{
    printf 'version=1\nphase=new-link-active\noperation=move\n'
    printf 'source=%s\n' "$(encode_field "$MOVE_REPAIR_SOURCE")"
    printf 'backup=%s\nstage=%s\n' "$(encode_field "")" "$(encode_field "")"
    printf 'final=%s\n' "$(encode_field "$MOVE_REPAIR_NEW")"
    printf 'old_destination=%s\n' "$(encode_field "$MOVE_REPAIR_OLD")"
} > "$MOVE_REPAIR_JOURNAL"
recover_incomplete_transaction "$MOVE_REPAIR_JOURNAL" || fail "$APPOFFLOAD_ERROR"
assert_link "$MOVE_REPAIR_SOURCE"
[ ! -e "$MOVE_REPAIR_OLD" ] || fail "interrupted move recovery retained the old verified copy"
[ "$(readlink "$MOVE_REPAIR_SOURCE")" = "$MOVE_REPAIR_NEW" ] || fail "interrupted move recovery changed the active link"

ORPHAN_SOURCE="$APP_SUPPORT_ROOT/Interrupted Commit"
ORPHAN_FINAL="$TARGET/$MANAGED_DIR_NAME/${USER:-$(id -un)}/Application Support/Interrupted Commit"
ORPHAN_JOURNAL="$TARGET/$MANAGED_DIR_NAME/.transactions/interrupted-commit.state"
mkdir -p "$ORPHAN_SOURCE" "$ORPHAN_FINAL"
printf 'same data\n' > "$ORPHAN_SOURCE/state"
printf 'same data\n' > "$ORPHAN_FINAL/state"
{
    printf 'version=1\nphase=verified\noperation=offload\n'
    printf 'source=%s\n' "$(encode_field "$ORPHAN_SOURCE")"
    printf 'backup=%s\n' "$(encode_field "$APP_SUPPORT_ROOT/.Interrupted Commit.appoffload-backup-test")"
    printf 'stage=%s\n' "$(encode_field "")"
    printf 'final=%s\n' "$(encode_field "$ORPHAN_FINAL")"
} > "$ORPHAN_JOURNAL"
health_scan > "$HEALTH_REPORT"
/usr/bin/awk -F '\t' -v p="$ORPHAN_FINAL" '$2 == "untracked-copy" && $4 == p {found=1} END {exit !found}' "$HEALTH_REPORT" || fail "orphan external copy was not visible in health scan"
recover_incomplete_transaction "$ORPHAN_JOURNAL" || fail "$APPOFFLOAD_ERROR"
assert_dir "$ORPHAN_SOURCE"
[ ! -e "$ORPHAN_FINAL" ] || fail "interrupted offload left an orphan external copy"

INTERRUPTED_CLEANUP_SOURCE="$APP_SUPPORT_ROOT/Interrupted Local Cleanup"
INTERRUPTED_CLEANUP_FINAL="$TARGET/$MANAGED_DIR_NAME/${USER:-$(id -un)}/Application Support/Interrupted Local Cleanup"
INTERRUPTED_CLEANUP_BACKUP="$APP_SUPPORT_ROOT/.Interrupted Local Cleanup.appoffload-backup-test"
INTERRUPTED_CLEANUP_JOURNAL="$TARGET/$MANAGED_DIR_NAME/.transactions/interrupted-local-cleanup.state"
mkdir -p "$INTERRUPTED_CLEANUP_FINAL" "$INTERRUPTED_CLEANUP_BACKUP"
printf 'complete external data\n' > "$INTERRUPTED_CLEANUP_FINAL/complete"
printf 'partial local data\n' > "$INTERRUPTED_CLEANUP_BACKUP/partial"
ln -s "$INTERRUPTED_CLEANUP_FINAL" "$INTERRUPTED_CLEANUP_SOURCE"
ACTIVE_SOURCE="$INTERRUPTED_CLEANUP_SOURCE" ACTIVE_BACKUP="$INTERRUPTED_CLEANUP_BACKUP" ACTIVE_STAGE="" ACTIVE_FINAL="$INTERRUPTED_CLEANUP_FINAL"
ACTIVE_JOURNAL="$INTERRUPTED_CLEANUP_JOURNAL" ACTIVE_OPERATION="offload" ACTIVE_PHASE="removing-local"
write_journal "$INTERRUPTED_CLEANUP_JOURNAL" "$ACTIVE_PHASE" || fail "could not write interrupted cleanup fixture"
rollback_active_transaction
assert_link "$INTERRUPTED_CLEANUP_SOURCE"
assert_file "$INTERRUPTED_CLEANUP_FINAL/complete"
assert_file "$INTERRUPTED_CLEANUP_BACKUP/partial"
[ "$(/usr/bin/awk -F= '$1 == "phase" {print $2; exit}' "$INTERRUPTED_CLEANUP_JOURNAL")" = "removing-local" ] || fail "interrupted local deletion was incorrectly marked aborted"
recover_incomplete_transaction "$INTERRUPTED_CLEANUP_JOURNAL" || fail "$APPOFFLOAD_ERROR"
assert_link "$INTERRUPTED_CLEANUP_SOURCE"
assert_file "$INTERRUPTED_CLEANUP_FINAL/complete"
[ ! -e "$INTERRUPTED_CLEANUP_BACKUP" ] || fail "recovery retained the partial local copy"

RESTORE_LIVE_SOURCE="$APP_SUPPORT_ROOT/Interrupted Live Restore"
RESTORE_OLD_FINAL="$TARGET/$MANAGED_DIR_NAME/${USER:-$(id -un)}/Application Support/Interrupted Live Restore"
RESTORE_LIVE_JOURNAL="$TARGET/$MANAGED_DIR_NAME/.transactions/interrupted-live-restore.state"
mkdir -p "$RESTORE_LIVE_SOURCE" "$RESTORE_OLD_FINAL"
printf 'new local changes\n' > "$RESTORE_LIVE_SOURCE/state"
printf 'older external data\n' > "$RESTORE_OLD_FINAL/state"
{
    printf 'version=1\nphase=local-active\noperation=restore\n'
    printf 'source=%s\n' "$(encode_field "$RESTORE_LIVE_SOURCE")"
    printf 'backup=%s\nstage=%s\n' "$(encode_field "")" "$(encode_field "")"
    printf 'final=%s\n' "$(encode_field "$RESTORE_OLD_FINAL")"
} > "$RESTORE_LIVE_JOURNAL"
recover_incomplete_transaction "$RESTORE_LIVE_JOURNAL" || fail "$APPOFFLOAD_ERROR"
[ "$(/bin/cat "$RESTORE_LIVE_SOURCE/state")" = "new local changes" ] || fail "restore recovery changed the live local folder"
[ ! -e "$RESTORE_OLD_FINAL" ] || fail "restore recovery retained the old external copy"
[ "$(/usr/bin/awk -F= '$1 == "phase" {print $2; exit}' "$RESTORE_LIVE_JOURNAL")" = "recovered" ] || fail "live restore journal remained incomplete"

DELETE_REPAIR_SOURCE="$APP_SUPPORT_ROOT/Interrupted Delete"
DELETE_REPAIR_FINAL="$TARGET/$MANAGED_DIR_NAME/${USER:-$(id -un)}/Application Support/Interrupted Delete"
DELETE_REPAIR_BACKUP="$APP_SUPPORT_ROOT/.Interrupted Delete.appoffload-delete-test"
DELETE_REPAIR_JOURNAL="$TARGET/$MANAGED_DIR_NAME/.transactions/interrupted-delete.state"
mkdir -p "$DELETE_REPAIR_FINAL"
printf 'partial data\n' > "$DELETE_REPAIR_FINAL/state"
ln -s "$DELETE_REPAIR_FINAL" "$DELETE_REPAIR_BACKUP"
{
    printf 'version=1\nphase=removing-external\noperation=delete\n'
    printf 'source=%s\n' "$(encode_field "$DELETE_REPAIR_SOURCE")"
    printf 'backup=%s\n' "$(encode_field "$DELETE_REPAIR_BACKUP")"
    printf 'stage=%s\n' "$(encode_field "")"
    printf 'final=%s\n' "$(encode_field "$DELETE_REPAIR_FINAL")"
} > "$DELETE_REPAIR_JOURNAL"
recover_incomplete_transaction "$DELETE_REPAIR_JOURNAL" || fail "$APPOFFLOAD_ERROR"
[ ! -e "$DELETE_REPAIR_FINAL" ] && [ ! -L "$DELETE_REPAIR_BACKUP" ] || fail "interrupted delete recovery retained data or its link"

if clean_health_staging "$TEST_ROOT/not-managed/.AppSupportOffload/user/Application Support/.appoffload-staging-bad"; then
    fail "staging cleanup accepted a path outside the volume root"
fi

echo "PASS: transactions, migration, health repair, guards, audit, and persistent locations"
