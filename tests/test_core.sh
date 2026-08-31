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
export APPOFFLOAD_ALLOW_ANY_TARGET=1
mkdir -p "$APPOFFLOAD_APP_SUPPORT_ROOT" "$APPOFFLOAD_VOLUMES_ROOT/External" "$APPOFFLOAD_VOLUMES_ROOT/External2" \
    "$APPOFFLOAD_APPLICATION_ROOTS" "$APPOFFLOAD_PREFERENCES_ROOT" "$APPOFFLOAD_SAVED_STATE_ROOT"

# shellcheck source=../lib/core.sh
. "$ROOT/lib/core.sh"

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

restore_folder "$SOURCE" || fail "$APPOFFLOAD_ERROR"
assert_dir "$SOURCE"
assert_file "$SOURCE/nested folder/data file.txt"
[ ! -e "$MOVED_DESTINATION" ] || fail "external copy retained after successful restore"
[ "$LAST_LOCAL_DELTA_BYTES" -lt 0 ] || fail "restore did not report consumed bytes"

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

if clean_health_staging "$TEST_ROOT/not-managed/.AppSupportOffload/user/Application Support/.appoffload-staging-bad"; then
    fail "staging cleanup accepted a path outside the volume root"
fi

echo "PASS: transactions, health repair, guards, audit, and persistent locations"
