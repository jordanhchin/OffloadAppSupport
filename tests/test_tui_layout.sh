#!/bin/bash

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
TEST_ROOT=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/appoffload-tui-tests.XXXXXX")
trap '/bin/rm -rf "$TEST_ROOT"' EXIT
export APPOFFLOAD_APP_SUPPORT_ROOT="$TEST_ROOT/Library/Application Support"
export APPOFFLOAD_VOLUMES_ROOT="$TEST_ROOT/Volumes"
export APPOFFLOAD_ALLOW_ANY_TARGET=1
mkdir -p "$APPOFFLOAD_APP_SUPPORT_ROOT" "$APPOFFLOAD_VOLUMES_ROOT/External"

# shellcheck source=../lib/core.sh
. "$ROOT/lib/core.sh"
# shellcheck source=../lib/tui.sh
. "$ROOT/lib/tui.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }
TEST_WIDTH=80
TEST_HEIGHT=24
terminal_width() { echo "$TEST_WIDTH"; }
terminal_height() { echo "$TEST_HEIGHT"; }
refresh_disk_status() {
    DISK_STATUS_ITEMS=(
        "Local 500 GB cap · 400 GB used · 80%"
        "External 1 TB cap · 500 GB used · 50%"
        "Archive 2 TB cap · 1 TB used · 50%"
        "Backup 4 TB cap · 3 TB used · 75%"
    )
}

refresh_disk_status
[ "$(status_bar_rows)" -eq 2 ] || fail "normal terminal did not reserve a compact two-row disk bar"
TEST_WIDTH=50
[ "$(status_bar_rows)" -eq 0 ] || fail "narrow terminal did not hide disk status"
TEST_WIDTH=140 TEST_HEIGHT=40
[ "$(status_bar_rows)" -ge 1 ] || fail "large terminal hid disk status"
HEADER_OUTPUT=$(draw_header "Layout test")
case "$HEADER_OUTPUT" in *$'\033[s'*|*$'\033[u'*) fail "renderer uses unreliable relative cursor save/restore" ;; esac
case "$HEADER_OUTPUT" in *$'\033[4;1H'*) ;; *) fail "renderer did not return to the absolute content origin" ;; esac

# Regression check: menu labels must contain only visible text. Embedding ANSI
# sequences caused the former restore menu to wrap and misalign.
USER_NAME=${USER:-$(id -un)}
DESTINATION="$APPOFFLOAD_VOLUMES_ROOT/External/$MANAGED_DIR_NAME/$USER_NAME/Application Support/Example"
mkdir -p "$DESTINATION"
printf 'data\n' > "$DESTINATION/state"
ln -s "$DESTINATION" "$APP_SUPPORT_ROOT/Example"
load_folder_menu offloaded
[ "${#MENU_LABELS[@]}" -eq 1 ] || fail "offloaded folder menu fixture was not found"
case "${MENU_LABELS[0]}" in *$'\033'*) fail "menu label contains ANSI control bytes" ;; esac

[ "$(printf '\033' | read_key)" = $'\033' ] || fail "single Escape key was swallowed"
[ "$(printf '\033[A' | read_key)" = $'\033[A' ] || fail "up arrow key was not decoded"

MENU_LABELS=("First app" "Second app" "Third app")
MENU_VALUES=("first" "second" "third")
printf ' j \n' > "$TEST_ROOT/multi-keys"
menu_select_multiple "Batch selection test" < "$TEST_ROOT/multi-keys" >/dev/null || fail "batch selection failed"
[ "${#SELECTED_VALUES[@]}" -eq 2 ] && [ "${SELECTED_VALUES[0]}" = "first" ] && [ "${SELECTED_VALUES[1]}" = "second" ] || fail "batch selection returned the wrong apps"

# Bash 3.2 treats an empty "${array[@]}" as unbound under set -u. These
# first-run menus must remain usable before any backup has been created.
list_app_migration_backups() { :; }
list_migratable_apps() { printf '2048\tExample\tcom.example.app\t%s\n' "$TEST_ROOT/Applications/Example.app"; }
list_managed_migration_offloads() { :; }
migration_offload_totals() { printf '0\t0\n'; }
MIGRATION_APP_CACHE_READY=0; MIGRATION_BACKUP_CACHE_READY=0
load_migratable_app_menu || fail "app menu failed with no backups"
[ "${#MENU_VALUES[@]}" -eq 1 ] || fail "app menu lost app when there were no backups"
load_migration_backup_menu || fail "backup menu failed with no backups"
[ "${#MENU_VALUES[@]}" -eq 0 ] || fail "empty backup menu contained a backup"
list_migratable_apps() { :; }
MIGRATION_APP_CACHE_READY=0
load_migratable_app_menu || fail "app menu failed with no apps or backups"
[ "${#MENU_VALUES[@]}" -eq 0 ] || fail "empty app menu contained an app"

list_app_migration_backups() { printf '1024\tExample\tcom.example.app\t2026-09-24\t%s\n' "$APPOFFLOAD_VOLUMES_ROOT/External/.AppSupportOffload/App Backups/com.example.app/example.appbackup"; }
MIGRATION_BACKUP_CACHE_READY=0
load_migration_backup_menu
case "${MENU_LABELS[0]}" in *'@ External'*) ;; *) fail "backup list did not show destination disk" ;; esac

list_migratable_apps() { printf x >> "$TEST_ROOT/app-scan-count"; printf '2048\tExample\tcom.example.app\t%s\n' "$TEST_ROOT/Applications/Example.app"; }
list_managed_migration_offloads() { :; }
migration_offload_totals() { printf '0\t0\n'; }
list_app_migration_backups() { printf x >> "$TEST_ROOT/backup-scan-count"; printf '1024\tExample\tcom.example.app\t2026-09-24\t%s\n' "$APPOFFLOAD_VOLUMES_ROOT/External/.AppSupportOffload/App Backups/com.example.app/example.appbackup"; }
MIGRATION_APP_CACHE_READY=0; MIGRATION_BACKUP_CACHE_READY=0
load_migratable_app_menu
case "${MENU_LABELS[0]}" in *'BACKUPS:1'*) ;; *) fail "app picker did not mark an existing backup" ;; esac
load_migratable_app_menu
[ "$(/usr/bin/wc -c < "$TEST_ROOT/app-scan-count")" -eq 1 ] || fail "app picker rescanned apps despite session cache"
[ "$(/usr/bin/wc -c < "$TEST_ROOT/backup-scan-count")" -eq 1 ] || fail "app picker rescanned backups despite session cache"
MIGRATION_BACKUP_CACHE_READY=0
load_migratable_app_menu
[ "$(/usr/bin/wc -c < "$TEST_ROOT/app-scan-count")" -eq 1 ] || fail "backup refresh unnecessarily rescanned apps"
[ "$(/usr/bin/wc -c < "$TEST_ROOT/backup-scan-count")" -eq 2 ] || fail "invalidated backup cache did not refresh"

echo "PASS: adaptive layout, backup locations, batch selection, and session cache"
