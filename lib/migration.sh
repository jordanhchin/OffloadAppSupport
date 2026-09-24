#!/bin/bash

# Whole-app migration backups. Sourced after core.sh; compatible with macOS Bash 3.2.

USER_LIBRARY_ROOT="${APPOFFLOAD_USER_LIBRARY_ROOT:-$HOME/Library}"
USER_APPLICATIONS_ROOT="${APPOFFLOAD_USER_APPLICATIONS_ROOT:-$HOME/Applications}"
APP_BACKUP_DIR_NAME="App Backups"
HDIUTIL_BIN="${APPOFFLOAD_HDIUTIL:-/usr/bin/hdiutil}"
LAST_MIGRATION_BACKUP=""
LAST_MIGRATION_APP_NAME=""
LAST_MIGRATION_ITEM_COUNT=0
LAST_MIGRATION_OFFLOADED_COUNT=0
ACTIVE_MIGRATION_COMMITTED_FILE=""
ACTIVE_MIGRATION_MOUNT=""
ACTIVE_MIGRATION_NETWORK_BUNDLE=""
MIGRATION_OPEN_MOUNT=""
MIGRATION_OPEN_PACKAGE=""

migration_safe_relative() {
    local path="$1" part rest
    [ -n "$path" ] || return 1
    case "$path" in /*|*$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
    rest="$path"
    while [ -n "$rest" ]; do
        case "$rest" in */*) part=${rest%%/*}; rest=${rest#*/} ;; *) part=$rest; rest="" ;; esac
        case "$part" in ""|.|..) return 1 ;; esac
    done
}

migration_app_info() {
    local app="$1" plist
    plist="$app/Contents/Info.plist"
    MIGRATION_BUNDLE_ID=$(plist_value "$plist" CFBundleIdentifier)
    MIGRATION_APP_NAME=$(plist_value "$plist" CFBundleDisplayName)
    [ -n "$MIGRATION_APP_NAME" ] || MIGRATION_APP_NAME=$(plist_value "$plist" CFBundleName)
    [ -n "$MIGRATION_APP_NAME" ] || MIGRATION_APP_NAME=$(/usr/bin/basename "$app" .app)
    MIGRATION_APP_VERSION=$(plist_value "$plist" CFBundleShortVersionString)
    [ -n "$MIGRATION_APP_VERSION" ] || MIGRATION_APP_VERSION=$(plist_value "$plist" CFBundleVersion)
    [ -n "$MIGRATION_BUNDLE_ID" ] || { APPOFFLOAD_ERROR="The app has no CFBundleIdentifier: $app"; return 1; }
    case "$MIGRATION_BUNDLE_ID" in *$'\n'*|*$'\r'*|*$'\t'*|*/*|*..*) APPOFFLOAD_ERROR="The app has an unsafe bundle identifier."; return 1 ;; esac
    case "$MIGRATION_APP_NAME$app" in *$'\n'*|*$'\r'*|*$'\t'*) APPOFFLOAD_ERROR="The app name or path contains an unsupported control character."; return 1 ;; esac
}

list_migratable_apps() {
    local root app name identifier size
    while IFS= read -r root; do
        [ -d "$root" ] || continue
        while IFS= read -r -d '' app; do
            identifier=$(plist_value "$app/Contents/Info.plist" CFBundleIdentifier)
            [ -n "$identifier" ] || continue
            name=$(plist_value "$app/Contents/Info.plist" CFBundleDisplayName)
            [ -n "$name" ] || name=$(plist_value "$app/Contents/Info.plist" CFBundleName)
            [ -n "$name" ] || name=$(/usr/bin/basename "$app" .app)
            case "$name$identifier$app" in *$'\n'*|*$'\r'*|*$'\t'*) continue ;; esac
            size=$(path_bytes "$app" 2>/dev/null || echo 0)
            printf '%s\t%s\t%s\t%s\n' "$size" "$name" "$identifier" "$app"
        done < <(/usr/bin/find "$root" -type d -name '*.app' -prune -print0 2>/dev/null)
    done < <(configured_app_roots)
}

resolve_migratable_app() {
    local requested="$1" size name identifier path match=""
    if [ -d "$requested" ] && [ "${requested##*.}" = "app" ]; then
        cd "$requested" 2>/dev/null && pwd -P
        return
    fi
    while IFS=$'\t' read -r size name identifier path; do
        if [ "$requested" = "$identifier" ] || [ "$requested" = "$name" ] || [ "$requested.app" = "$(/usr/bin/basename "$path")" ] || [ "$requested" = "$(/usr/bin/basename "$path")" ]; then
            [ -z "$match" ] || { APPOFFLOAD_ERROR="More than one installed app matches '$requested'; use its full path."; return 1; }
            match="$path"
        fi
    done < <(list_migratable_apps)
    [ -n "$match" ] || { APPOFFLOAD_ERROR="No installed app matches: $requested"; return 1; }
    printf '%s\n' "$match"
}

migration_group_identifiers() {
    local app="$1" temp line
    temp=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/appoffload-entitlements.XXXXXX") || return
    if /usr/bin/codesign -d --entitlements "$temp" "$app" >/dev/null 2>&1 && [ -s "$temp" ]; then
        # Current macOS emits an abstract [Key]/[String] representation here;
        # older releases may emit a plist. Normalize either form.
        if /usr/bin/plutil -lint "$temp" >/dev/null 2>&1; then
            /usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups' "$temp" 2>/dev/null
        else
            /usr/bin/awk '
                /\[Key\] com\.apple\.security\.application-groups$/ {inside=1; next}
                inside && /\[Key\]/ {exit}
                inside && /\[String\]/ {sub(/^.*\[String\][[:space:]]*/, ""); print}
            ' "$temp"
        fi | while IFS= read -r line; do
            line=$(printf '%s' "$line" | /usr/bin/sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            case "$line" in ""|Array\ \{|\}) continue ;; esac
            case "$line" in *[!A-Za-z0-9._-]*) continue ;; esac
            printf '%s\n' "$line"
        done
    fi
    /bin/rm -f "$temp"
}

migration_emit_item() {
    local category="$1" relative="$2" source="$3" actual size key probe
    [ -e "$source" ] || [ -L "$source" ] || return 0
    migration_safe_relative "$relative" || return 0
    case "$source" in *$'\n'*|*$'\r'*|*$'\t'*) return 0 ;; esac
    key="$category/$relative"
    case "$MIGRATION_SEEN" in *$'\n'"$key"$'\n'*) return 0 ;; esac
    probe="$relative"
    while case "$probe" in */*) true ;; *) false ;; esac; do
        probe=${probe%/*}
        case "$MIGRATION_SEEN" in *$'\n'"$category/$probe"$'\n'*) return 0 ;; esac
    done
    MIGRATION_SEEN="$MIGRATION_SEEN$key"$'\n'
    actual=$(migration_materialized_source "$source" 2>/dev/null || printf '%s' "$source")
    size=$(path_bytes "$actual" 2>/dev/null || echo 0)
    printf '%s\t%s\t%s\t%s\n' "$size" "$category" "$relative" "$source"
}

migration_materialized_source() {
    local source="$1" raw target
    [ -L "$source" ] || { printf '%s\n' "$source"; return 0; }
    target=$(managed_link_destination "$source" 2>/dev/null || true)
    if [ -n "$target" ] && [ -e "$target" ]; then printf '%s\n' "$target"; return 0; fi
    raw=$(/usr/bin/readlink "$source") || return 1
    case "$raw" in /*) target="$raw" ;; *) target="$(/usr/bin/dirname "$source")/$raw" ;; esac
    [ -e "$target" ] || return 1
    if [ -d "$target" ]; then cd "$target" 2>/dev/null && pwd -P; else printf '%s\n' "$target"; fi
}

migration_source_kind() {
    local source="$1"
    if [ -L "$source" ] && managed_link_destination "$source" >/dev/null 2>&1; then printf 'OFFLOADED\n'
    elif [ -L "$source" ]; then printf 'LINKED\n'
    else printf 'LOCAL\n'
    fi
}

# Output: allocated bytes, category (App or Library), relative restore path, source.
app_migration_inventory() {
    local app="$1" id name candidate group label plist base relative leaf_key name_key id_key
    APPOFFLOAD_ERROR=""
    [ -d "$app" ] && [ "${app##*.}" = "app" ] || { APPOFFLOAD_ERROR="Not an application bundle: $app"; return 1; }
    migration_app_info "$app" || return 1
    id="$MIGRATION_BUNDLE_ID"; name="$MIGRATION_APP_NAME"; MIGRATION_SEEN=$'\n'
    migration_emit_item App "$(/usr/bin/basename "$app")" "$app"

    for base in "Application Support" "Caches" "Logs" "WebKit" "HTTPStorages"; do
        for candidate in "$USER_LIBRARY_ROOT/$base/$id" "$USER_LIBRARY_ROOT/$base/$id".* "$USER_LIBRARY_ROOT/$base/$name"; do
            [ -e "$candidate" ] || [ -L "$candidate" ] || continue
            migration_emit_item Library "$base/${candidate##*/}" "$candidate"
        done
    done
    # Catch common vendor nesting such as Application Support/Google/Chrome,
    # while remaining conservative: only a leaf matching the app name or the
    # final bundle-ID component is accepted, and already-selected parents win.
    name_key=$(normalize_identity "$name"); id_key=$(normalize_identity "${id##*.}")
    while IFS= read -r -d '' candidate; do
        leaf_key=$(normalize_identity "${candidate##*/}")
        if [ -n "$leaf_key" ] && { [ "$leaf_key" = "$name_key" ] || [ "$leaf_key" = "$id_key" ]; }; then
            relative=${candidate#"$USER_LIBRARY_ROOT/Application Support/"}
            migration_emit_item Library "Application Support/$relative" "$candidate"
        fi
    done < <(/usr/bin/find "$USER_LIBRARY_ROOT/Application Support" -mindepth 1 -maxdepth 2 -type d -print0 2>/dev/null)
    for candidate in "$USER_LIBRARY_ROOT/Containers/$id" "$USER_LIBRARY_ROOT/Containers/$id".*; do
        [ -e "$candidate" ] || [ -L "$candidate" ] || continue
        migration_emit_item Library "Containers/${candidate##*/}" "$candidate"
    done
    for candidate in "$USER_LIBRARY_ROOT/Application Scripts/$id" "$USER_LIBRARY_ROOT/Application Scripts/$id".*; do
        [ -e "$candidate" ] || [ -L "$candidate" ] || continue
        migration_emit_item Library "Application Scripts/${candidate##*/}" "$candidate"
    done
    for candidate in "$USER_LIBRARY_ROOT/Preferences/$id.plist" "$USER_LIBRARY_ROOT/Preferences/$id".*.plist "$USER_LIBRARY_ROOT/Preferences/$name.plist"; do
        [ -e "$candidate" ] || [ -L "$candidate" ] || continue
        migration_emit_item Library "Preferences/${candidate##*/}" "$candidate"
    done
    for candidate in "$USER_LIBRARY_ROOT/Preferences/ByHost/$id".*.plist; do
        [ -e "$candidate" ] || [ -L "$candidate" ] || continue
        migration_emit_item Library "Preferences/ByHost/${candidate##*/}" "$candidate"
    done
    for candidate in "$USER_LIBRARY_ROOT/Saved Application State/$id.savedState" "$USER_LIBRARY_ROOT/Saved Application State/$name.savedState"; do
        [ -e "$candidate" ] || [ -L "$candidate" ] || continue
        migration_emit_item Library "Saved Application State/${candidate##*/}" "$candidate"
    done
    for candidate in "$USER_LIBRARY_ROOT/Cookies/$id.binarycookies" "$USER_LIBRARY_ROOT/Cookies/$id".*; do
        [ -e "$candidate" ] || [ -L "$candidate" ] || continue
        migration_emit_item Library "Cookies/${candidate##*/}" "$candidate"
    done
    while IFS= read -r group; do
        [ -n "$group" ] || continue
        candidate="$USER_LIBRARY_ROOT/Group Containers/$group"
        migration_emit_item Library "Group Containers/$group" "$candidate"
        candidate="$USER_LIBRARY_ROOT/Application Scripts/$group"
        migration_emit_item Library "Application Scripts/$group" "$candidate"
    done < <(migration_group_identifiers "$app")
    for plist in "$USER_LIBRARY_ROOT/LaunchAgents"/*.plist; do
        [ -f "$plist" ] || continue
        label=$(plist_value "$plist" Label)
        case "$label" in "$id"|"$id".*) migration_emit_item Library "LaunchAgents/${plist##*/}" "$plist" ;; esac
    done
}

migration_verify_pair() {
    local source="$1" destination="$2" workdir="$3" label="$4" source_manifest destination_manifest
    if [ -L "$source" ]; then
        [ -L "$destination" ] && [ "$(/usr/bin/readlink "$source")" = "$(/usr/bin/readlink "$destination")" ] || { APPOFFLOAD_ERROR="Symlink verification failed for $label"; return 1; }
    elif [ -f "$source" ]; then
        [ -f "$destination" ] && /usr/bin/cmp -s "$source" "$destination" || { APPOFFLOAD_ERROR="File verification failed for $label"; return 1; }
    elif [ -d "$source" ]; then
        source_manifest="$workdir/source-$label.tsv"; destination_manifest="$workdir/destination-$label.tsv"
        create_manifest "$source" "$source_manifest" || return 1
        create_manifest "$destination" "$destination_manifest" || return 1
        /usr/bin/cmp -s "$source_manifest" "$destination_manifest" || { APPOFFLOAD_ERROR="SHA-256 verification failed for $label"; return 1; }
    else
        APPOFFLOAD_ERROR="Unsupported migration item: $source"
        return 1
    fi
}

create_app_migration_folder_backup() {
    local app="$1" target="$2" inventory total free required id safe_id timestamp root final stage payload workdir
    local count=0 index=0 offloaded_count=0 size category relative source actual destination encoded_source
    APPOFFLOAD_ERROR=""; LAST_EXTERNAL_BYTES=0; LAST_LOCAL_DELTA_BYTES=0; LAST_MIGRATION_BACKUP=""; LAST_MIGRATION_ITEM_COUNT=0; LAST_MIGRATION_OFFLOADED_COUNT=0
    migration_app_info "$app" || return 1
    [ -d "$target" ] && [ -w "$target" ] || { APPOFFLOAD_ERROR="Target is not a mounted writable directory: $target"; return 1; }
    if [ "${APPOFFLOAD_ALLOW_ANY_TARGET:-0}" != "1" ]; then case "$target" in "$VOLUMES_ROOT"/*) ;; *) APPOFFLOAD_ERROR="Target must be a mounted volume below $VOLUMES_ROOT"; return 1 ;; esac; fi
    ensure_compatible_filesystem "$target" || return 1
    inventory=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/appoffload-migration-inventory.XXXXXX") || return 1
    app_migration_inventory "$app" > "$inventory" || { /bin/rm -f "$inventory"; return 1; }
    count=$(/usr/bin/awk 'END {print NR+0}' "$inventory")
    total=$(/usr/bin/awk -F '\t' '{sum += $1} END {printf "%.0f", sum+0}' "$inventory")
    [ "$count" -gt 0 ] || { /bin/rm -f "$inventory"; APPOFFLOAD_ERROR="No migration items were found."; return 1; }
    free=$(available_bytes "$target"); required=$((total + total / 20 + 67108864))
    [ -n "$free" ] && [ "$free" -ge "$required" ] || { /bin/rm -f "$inventory"; APPOFFLOAD_ERROR="Not enough target space: need $(human_bytes "$required"), have $(human_bytes "${free:-0}")."; return 1; }
    acquire_lock || { /bin/rm -f "$inventory"; return 1; }
    while IFS=$'\t' read -r size category relative source; do
        [ "$(migration_source_kind "$source")" = "OFFLOADED" ] && offloaded_count=$((offloaded_count + 1))
        actual=$(migration_materialized_source "$source" 2>/dev/null || true)
        [ -n "$actual" ] && { [ -e "$actual" ] || [ -L "$actual" ]; } || { /bin/rm -f "$inventory"; release_lock; APPOFFLOAD_ERROR="Associated data is unavailable (possibly an unmounted offload): $source"; return 1; }
        ensure_not_in_use "$actual" || { /bin/rm -f "$inventory"; release_lock; return 1; }
    done < "$inventory"

    id="$MIGRATION_BUNDLE_ID"; safe_id=$(printf '%s' "$id" | /usr/bin/tr -cd '[:alnum:]._-' ); timestamp=$(/bin/date +%Y%m%d-%H%M%S)
    root="$target/$MANAGED_DIR_NAME/$APP_BACKUP_DIR_NAME/$safe_id"
    final="$root/$timestamp-$$-$(printf '%s' "$MIGRATION_APP_NAME" | /usr/bin/tr '/:' '__').appbackup"
    stage="$root/.appoffload-staging-$timestamp-$$.appbackup"; payload="$stage/payload"; workdir="${TMPDIR:-/tmp}/appoffload-migration-$timestamp-$$"
    [ ! -e "$final" ] || { /bin/rm -f "$inventory"; release_lock; APPOFFLOAD_ERROR="Migration backup already exists: $final"; return 1; }
    /bin/mkdir -p "$payload/App" "$payload/Library" "$workdir" || { /bin/rm -f "$inventory"; release_lock; APPOFFLOAD_ERROR="Could not create migration staging folders."; return 1; }
    ACTIVE_SOURCE="$app" ACTIVE_STAGE="$stage" ACTIVE_WORKDIR="$workdir" ACTIVE_PHASE="migration-backup"
    while IFS=$'\t' read -r size category relative source; do
        index=$((index + 1)); actual=$(migration_materialized_source "$source")
        destination="$payload/$category/$relative"
        /bin/mkdir -p "$(/usr/bin/dirname "$destination")" || { APPOFFLOAD_ERROR="Could not create backup path for $relative"; rollback_active_transaction; /bin/rm -f "$inventory"; return 1; }
        emit_progress "Backing up app" "$((index * 85 / count))" "$index of $count: $relative"
        copy_with_progress "$actual" "$destination" "$size" || { rollback_active_transaction; /bin/rm -f "$inventory"; return 1; }
        migration_verify_pair "$actual" "$destination" "$workdir" "$index" || { rollback_active_transaction; /bin/rm -f "$inventory"; return 1; }
    done < "$inventory"
    create_manifest "$payload" "$stage/checksums.tsv" || { rollback_active_transaction; /bin/rm -f "$inventory"; return 1; }
    {
        printf 'format=1\nstatus=complete\ncreated_at=%s\n' "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'bundle_id=%s\napp_name=%s\napp_version=%s\noriginal_app_path=%s\n' "$(encode_field "$id")" "$(encode_field "$MIGRATION_APP_NAME")" "$(encode_field "$MIGRATION_APP_VERSION")" "$(encode_field "$app")"
        printf 'item_count=%s\ntotal_bytes=%s\nsource_macos=%s\n' "$count" "$total" "$(encode_field "$(/usr/bin/sw_vers -productVersion 2>/dev/null || echo unknown)")"
    } > "$stage/metadata.conf"
    while IFS=$'\t' read -r size category relative source; do
        encoded_source=$(encode_field "$source")
        printf '%s\t%s\t%s\t%s\n' "$category" "$(encode_field "$relative")" "$encoded_source" "$size"
    done < "$inventory" > "$stage/items.tsv"
    /bin/mv "$stage" "$final" || { APPOFFLOAD_ERROR="Could not commit the migration backup."; rollback_active_transaction; /bin/rm -f "$inventory"; return 1; }
    ACTIVE_STAGE=""; /bin/rm -rf "$workdir"; /bin/rm -f "$inventory"; release_lock; clear_active_transaction
    LAST_EXTERNAL_BYTES=$total; LAST_MIGRATION_BACKUP="$final"; LAST_MIGRATION_APP_NAME="$MIGRATION_APP_NAME"; LAST_MIGRATION_ITEM_COUNT=$count; LAST_MIGRATION_OFFLOADED_COUNT=$offloaded_count
    emit_progress "Complete" 100 "$count items verified"
}

migration_filesystem_personality() {
    local target="$1" personality device
    if [ -f "$target/.appoffload-filesystem-personality" ]; then
        /usr/bin/head -n 1 "$target/.appoffload-filesystem-personality"
        return
    fi
    personality=$(filesystem_personality "$target")
    if [ -z "$personality" ]; then
        device=$(/bin/df -P "$target" 2>/dev/null | /usr/bin/awk 'NR == 2 {print $1}')
        personality=$(/sbin/mount 2>/dev/null | /usr/bin/awk -v device="$device" '
            index($0, device " on ") == 1 {line=$0; sub(/^.*\(/, "", line); sub(/,.*/, "", line); print line; exit}
        ')
    fi
    printf '%s\n' "$personality"
}

migration_target_kind() {
    local personality
    personality=$(migration_filesystem_personality "$1" | /usr/bin/tr '[:upper:]' '[:lower:]')
    case "$personality" in
        *smb*|*cifs*|*nfs*) printf 'network\n' ;;
        *apfs*|*"mac os extended"*|hfs*) printf 'native\n' ;;
        *) [ "${APPOFFLOAD_ALLOW_ANY_TARGET:-0}" = "1" ] && printf 'native\n' || printf 'unsupported\n' ;;
    esac
}

migration_attach_sparsebundle() {
    local bundle="$1" readonly="${2:-0}" output mount
    if [ "$readonly" = "1" ]; then
        output=$("$HDIUTIL_BIN" attach -readonly -nobrowse -noautoopen "$bundle" 2>&1) || { APPOFFLOAD_ERROR="Could not mount network migration bundle: $output"; return 1; }
    else
        output=$("$HDIUTIL_BIN" attach -nobrowse -noautoopen "$bundle" 2>&1) || { APPOFFLOAD_ERROR="Could not mount network migration bundle: $output"; return 1; }
    fi
    mount=$(printf '%s\n' "$output" | /usr/bin/awk -F '\t' '$NF ~ /^\// {value=$NF} END {print value}')
    [ -n "$mount" ] && [ -d "$mount" ] || { APPOFFLOAD_ERROR="The network migration image mounted without a readable mount point."; return 1; }
    printf '%s\n' "$mount"
}

migration_detach_sparsebundle() {
    local mount="$1" output
    [ -n "$mount" ] || return 0
    output=$("$HDIUTIL_BIN" detach "$mount" 2>&1) || { APPOFFLOAD_ERROR="Migration data is safe, but its disk image could not be unmounted: $output"; return 1; }
}

migration_network_bundle_safe() {
    case "$1" in "$VOLUMES_ROOT"/*/"$MANAGED_DIR_NAME"/"$APP_BACKUP_DIR_NAME"/*/*.appmigration.sparsebundle) return 0 ;; *) return 1 ;; esac
}

create_app_migration_network_backup() {
    local app="$1" target="$2" inventory total free required capacity_mb timestamp safe_id safe_name root bundle sidecar volume_name mount
    local saved_name saved_count saved_offloaded saved_bytes
    APPOFFLOAD_ERROR=""; LAST_MIGRATION_BACKUP=""; LAST_MIGRATION_ITEM_COUNT=0; LAST_MIGRATION_OFFLOADED_COUNT=0
    migration_app_info "$app" || return 1
    [ -x "$HDIUTIL_BIN" ] || { APPOFFLOAD_ERROR="hdiutil is required for a network migration destination."; return 1; }
    inventory=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/appoffload-network-inventory.XXXXXX") || return 1
    app_migration_inventory "$app" > "$inventory" || { /bin/rm -f "$inventory"; return 1; }
    total=$(/usr/bin/awk -F '\t' '{sum += $1} END {printf "%.0f", sum+0}' "$inventory"); /bin/rm -f "$inventory"
    required=$((total + total / 20 + 67108864)); free=$(available_bytes "$target")
    [ -n "$free" ] && [ "$free" -ge "$required" ] || { APPOFFLOAD_ERROR="Not enough network space: need $(human_bytes "$required"), have $(human_bytes "${free:-0}")."; return 1; }
    capacity_mb=$(((total + total / 4 + 536870912 + 1048575) / 1048576))
    [ "$capacity_mb" -lt 1024 ] && capacity_mb=1024
    safe_id=$(printf '%s' "$MIGRATION_BUNDLE_ID" | /usr/bin/tr -cd '[:alnum:]._-' ); safe_name=$(printf '%s' "$MIGRATION_APP_NAME" | /usr/bin/tr '/:' '__')
    timestamp=$(/bin/date +%Y%m%d-%H%M%S); root="$target/$MANAGED_DIR_NAME/$APP_BACKUP_DIR_NAME/$safe_id"
    bundle="$root/$timestamp-$$-$safe_name.appmigration.sparsebundle"; sidecar="$bundle.appoffload.conf"; volume_name="AppMigration-$safe_id-$$"
    /bin/mkdir -p "$root" || { APPOFFLOAD_ERROR="Could not create the network migration folder."; return 1; }
    [ ! -e "$bundle" ] && [ ! -e "$sidecar" ] || { APPOFFLOAD_ERROR="Network migration destination already exists."; return 1; }
    emit_progress "Preparing network backup" 2 "Creating APFS sparsebundle"
    if ! "$HDIUTIL_BIN" create -type SPARSEBUNDLE -fs APFS -size "${capacity_mb}m" -volname "$volume_name" "$bundle" >/dev/null 2>&1; then
        APPOFFLOAD_ERROR="Could not create an APFS sparsebundle on the network share."
        return 1
    fi
    migration_network_bundle_safe "$bundle" || { APPOFFLOAD_ERROR="Safety guard refused the network bundle path."; return 1; }
    ACTIVE_MIGRATION_NETWORK_BUNDLE="$bundle"
    mount=$(migration_attach_sparsebundle "$bundle" 0) || { /bin/rm -rf "$bundle"; ACTIVE_MIGRATION_NETWORK_BUNDLE=""; return 1; }
    ACTIVE_MIGRATION_MOUNT="$mount"
    if ! create_app_migration_folder_backup "$app" "$mount"; then
        migration_detach_sparsebundle "$mount" >/dev/null 2>&1 || true
        ACTIVE_MIGRATION_MOUNT=""; /bin/rm -rf "$bundle"; ACTIVE_MIGRATION_NETWORK_BUNDLE=""
        return 1
    fi
    saved_name="$LAST_MIGRATION_APP_NAME"; saved_count="$LAST_MIGRATION_ITEM_COUNT"; saved_offloaded="$LAST_MIGRATION_OFFLOADED_COUNT"; saved_bytes="$LAST_EXTERNAL_BYTES"
    if ! migration_detach_sparsebundle "$mount"; then ACTIVE_MIGRATION_MOUNT="$mount"; return 1; fi
    ACTIVE_MIGRATION_MOUNT=""
    {
        printf 'format=1\ntransport=sparsebundle\ncreated_at=%s\n' "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'app_name=%s\nbundle_id=%s\ntotal_bytes=%s\n' "$(encode_field "$saved_name")" "$(encode_field "$MIGRATION_BUNDLE_ID")" "$saved_bytes"
    } > "$sidecar" || { APPOFFLOAD_ERROR="The sparsebundle is complete, but its catalog metadata could not be written."; ACTIVE_MIGRATION_NETWORK_BUNDLE=""; return 1; }
    ACTIVE_MIGRATION_NETWORK_BUNDLE=""
    LAST_MIGRATION_APP_NAME="$saved_name"; LAST_MIGRATION_ITEM_COUNT="$saved_count"; LAST_MIGRATION_OFFLOADED_COUNT="$saved_offloaded"; LAST_EXTERNAL_BYTES="$saved_bytes"; LAST_MIGRATION_BACKUP="$bundle"
    emit_progress "Complete" 100 "$saved_count items verified inside APFS sparsebundle"
}

create_app_migration_backup() {
    local app="$1" target="$2" kind
    [ -d "$target" ] && [ -w "$target" ] || { APPOFFLOAD_ERROR="Target is not a mounted writable directory: $target"; return 1; }
    if [ "${APPOFFLOAD_ALLOW_ANY_TARGET:-0}" != "1" ]; then case "$target" in "$VOLUMES_ROOT"/*) ;; *) APPOFFLOAD_ERROR="Target must be mounted below $VOLUMES_ROOT"; return 1 ;; esac; fi
    kind=$(migration_target_kind "$target")
    case "$kind" in
        native) create_app_migration_folder_backup "$app" "$target" ;;
        network) create_app_migration_network_backup "$app" "$target" ;;
        *) APPOFFLOAD_ERROR="Unsupported migration target filesystem: $(migration_filesystem_personality "$target"). Use APFS, Mac OS Extended, SMB, or NFS."; return 1 ;;
    esac
}

list_app_migration_backups() {
    local volume backup metadata name id created total sidecar
    for volume in "$VOLUMES_ROOT"/*; do
        [ -d "$volume" ] || continue
        while IFS= read -r -d '' backup; do
            case "${backup##*/}" in .appoffload-staging-*) continue ;; esac
            metadata="$backup/metadata.conf"; [ -f "$metadata" ] || continue
            name=$(decode_field "$(/usr/bin/awk -F= '$1 == "app_name" {print substr($0,index($0,"=")+1);exit}' "$metadata")")
            id=$(decode_field "$(/usr/bin/awk -F= '$1 == "bundle_id" {print substr($0,index($0,"=")+1);exit}' "$metadata")")
            created=$(/usr/bin/awk -F= '$1 == "created_at" {print substr($0,index($0,"=")+1);exit}' "$metadata")
            total=$(/usr/bin/awk -F= '$1 == "total_bytes" {print $2;exit}' "$metadata")
            printf '%s\t%s\t%s\t%s\t%s\n' "${total:-0}" "$name" "$id" "$created" "$backup"
        done < <(/usr/bin/find "$volume/$MANAGED_DIR_NAME/$APP_BACKUP_DIR_NAME" -type d -name '*.appbackup' -print0 2>/dev/null)
        while IFS= read -r -d '' sidecar; do
            backup=${sidecar%.appoffload.conf}; [ -d "$backup" ] || continue
            name=$(decode_field "$(/usr/bin/awk -F= '$1 == "app_name" {print substr($0,index($0,"=")+1);exit}' "$sidecar")")
            id=$(decode_field "$(/usr/bin/awk -F= '$1 == "bundle_id" {print substr($0,index($0,"=")+1);exit}' "$sidecar")")
            created=$(/usr/bin/awk -F= '$1 == "created_at" {print substr($0,index($0,"=")+1);exit}' "$sidecar")
            total=$(/usr/bin/awk -F= '$1 == "total_bytes" {print $2;exit}' "$sidecar")
            printf '%s\t%s\t%s\t%s\t%s\n' "${total:-0}" "$name" "$id" "$created" "$backup"
        done < <(/usr/bin/find "$volume/$MANAGED_DIR_NAME/$APP_BACKUP_DIR_NAME" -type f -name '*.appmigration.sparsebundle.appoffload.conf' -print0 2>/dev/null)
    done
}

migration_open_backup_source() {
    local source="$1" mount package count
    MIGRATION_OPEN_MOUNT=""; MIGRATION_OPEN_PACKAGE=""
    case "$source" in
        *.appmigration.sparsebundle)
            migration_network_bundle_safe "$source" || { APPOFFLOAD_ERROR="Safety guard refused the network migration bundle path."; return 1; }
            mount=$(migration_attach_sparsebundle "$source" 1) || return 1
            count=0
            while IFS= read -r -d '' package; do MIGRATION_OPEN_PACKAGE="$package"; count=$((count + 1)); done < <(/usr/bin/find "$mount/$MANAGED_DIR_NAME/$APP_BACKUP_DIR_NAME" -type d -name '*.appbackup' -print0 2>/dev/null)
            if [ "$count" -ne 1 ]; then migration_detach_sparsebundle "$mount" >/dev/null 2>&1 || true; MIGRATION_OPEN_PACKAGE=""; APPOFFLOAD_ERROR="Network migration bundle must contain exactly one app backup."; return 1; fi
            MIGRATION_OPEN_MOUNT="$mount"
            ;;
        *.appbackup)
            MIGRATION_OPEN_PACKAGE="$source"
            ;;
        *) APPOFFLOAD_ERROR="Unknown migration backup format: $source"; return 1 ;;
    esac
    verify_app_migration_backup "$MIGRATION_OPEN_PACKAGE" || { migration_close_backup_source; return 1; }
}

migration_close_backup_source() {
    local saved_error="$APPOFFLOAD_ERROR"
    if [ -n "${MIGRATION_OPEN_MOUNT:-}" ]; then migration_detach_sparsebundle "$MIGRATION_OPEN_MOUNT" >/dev/null 2>&1 || true; fi
    MIGRATION_OPEN_MOUNT=""; MIGRATION_OPEN_PACKAGE=""; APPOFFLOAD_ERROR="$saved_error"
}

verify_app_migration_source() {
    local source="$1"
    migration_open_backup_source "$source" || return 1
    migration_close_backup_source
}

restore_app_migration_source() {
    local source="$1" app_target_root="${2:-}" result
    migration_open_backup_source "$source" || return 1
    restore_app_migration_backup "$MIGRATION_OPEN_PACKAGE" "$app_target_root"; result=$?
    migration_close_backup_source
    return "$result"
}

migration_native_backup_safe() {
    case "$1" in "$VOLUMES_ROOT"/*/"$MANAGED_DIR_NAME"/"$APP_BACKUP_DIR_NAME"/*/*.appbackup) return 0 ;; *) return 1 ;; esac
}

migration_read_package_info() {
    local package="$1" metadata
    metadata="$package/metadata.conf"
    MIGRATION_PACKAGE_NAME=$(decode_field "$(/usr/bin/awk -F= '$1 == "app_name" {print substr($0,index($0,"=")+1);exit}' "$metadata")")
    MIGRATION_PACKAGE_ID=$(decode_field "$(/usr/bin/awk -F= '$1 == "bundle_id" {print substr($0,index($0,"=")+1);exit}' "$metadata")")
    MIGRATION_PACKAGE_CREATED=$(/usr/bin/awk -F= '$1 == "created_at" {print substr($0,index($0,"=")+1);exit}' "$metadata")
    MIGRATION_PACKAGE_BYTES=$(/usr/bin/awk -F= '$1 == "total_bytes" {print $2;exit}' "$metadata")
    case "$MIGRATION_PACKAGE_BYTES" in ''|*[!0-9]*) APPOFFLOAD_ERROR="Migration package size metadata is invalid."; return 1 ;; esac
}

migration_copy_package_native() {
    local package="$1" target="$2" safe_id root final stage workdir copy_bytes free required
    safe_id=$(printf '%s' "$MIGRATION_PACKAGE_ID" | /usr/bin/tr -cd '[:alnum:]._-' ); root="$target/$MANAGED_DIR_NAME/$APP_BACKUP_DIR_NAME/$safe_id"
    final="$root/$(/usr/bin/basename "$package")"; stage="$root/.appoffload-staging-move-$$.appbackup"; workdir="${TMPDIR:-/tmp}/appoffload-migration-move-$$"
    [ ! -e "$final" ] || { APPOFFLOAD_ERROR="A migration backup with that name already exists on the target."; return 1; }
    copy_bytes=$(path_bytes "$package"); free=$(available_bytes "$target"); required=$((copy_bytes + copy_bytes / 20 + 67108864))
    [ -n "$free" ] && [ "$free" -ge "$required" ] || { APPOFFLOAD_ERROR="Not enough target space for the backup move."; return 1; }
    /bin/mkdir -p "$root" "$workdir" || { APPOFFLOAD_ERROR="Could not create backup-move staging."; return 1; }
    ACTIVE_SOURCE="$package" ACTIVE_STAGE="$stage" ACTIVE_WORKDIR="$workdir" ACTIVE_PHASE="migration-backup-move"
    copy_with_progress "$package" "$stage" "$copy_bytes" || { rollback_active_transaction; return 1; }
    migration_verify_pair "$package" "$stage" "$workdir" "backup-move" || { rollback_active_transaction; return 1; }
    /bin/mv "$stage" "$final" || { APPOFFLOAD_ERROR="Could not commit the moved backup."; rollback_active_transaction; return 1; }
    ACTIVE_STAGE=""; /bin/rm -rf "$workdir"; clear_active_transaction
    LAST_MIGRATION_BACKUP="$final"
}

migration_copy_package_network() {
    local package="$1" target="$2" safe_id safe_name timestamp root bundle sidecar volume_name capacity_mb mount image_root destination workdir copy_bytes
    safe_id=$(printf '%s' "$MIGRATION_PACKAGE_ID" | /usr/bin/tr -cd '[:alnum:]._-' ); safe_name=$(printf '%s' "$MIGRATION_PACKAGE_NAME" | /usr/bin/tr '/:' '__')
    timestamp=$(/bin/date +%Y%m%d-%H%M%S); root="$target/$MANAGED_DIR_NAME/$APP_BACKUP_DIR_NAME/$safe_id"
    bundle="$root/$timestamp-$$-$safe_name.appmigration.sparsebundle"; sidecar="$bundle.appoffload.conf"; volume_name="AppMigration-$safe_id-$$"
    copy_bytes=$(path_bytes "$package"); capacity_mb=$(((copy_bytes + copy_bytes / 4 + 536870912 + 1048575) / 1048576)); [ "$capacity_mb" -lt 1024 ] && capacity_mb=1024
    /bin/mkdir -p "$root" || { APPOFFLOAD_ERROR="Could not create network backup folder."; return 1; }
    if ! "$HDIUTIL_BIN" create -type SPARSEBUNDLE -fs APFS -size "${capacity_mb}m" -volname "$volume_name" "$bundle" >/dev/null 2>&1; then APPOFFLOAD_ERROR="Could not create the destination sparsebundle."; return 1; fi
    ACTIVE_MIGRATION_NETWORK_BUNDLE="$bundle"
    mount=$(migration_attach_sparsebundle "$bundle" 0) || { /bin/rm -rf "$bundle"; ACTIVE_MIGRATION_NETWORK_BUNDLE=""; return 1; }
    ACTIVE_MIGRATION_MOUNT="$mount"; image_root="$mount/$MANAGED_DIR_NAME/$APP_BACKUP_DIR_NAME/$safe_id"; destination="$image_root/$(/usr/bin/basename "$package")"; workdir="${TMPDIR:-/tmp}/appoffload-migration-network-move-$$"
    /bin/mkdir -p "$image_root" "$workdir" || { APPOFFLOAD_ERROR="Could not create staging inside the sparsebundle."; rollback_active_transaction; return 1; }
    ACTIVE_SOURCE="$package" ACTIVE_WORKDIR="$workdir" ACTIVE_PHASE="migration-network-move"
    copy_with_progress "$package" "$destination" "$copy_bytes" || { rollback_active_transaction; return 1; }
    migration_verify_pair "$package" "$destination" "$workdir" "network-backup-move" || { rollback_active_transaction; return 1; }
    /bin/rm -rf "$workdir"
    if ! migration_detach_sparsebundle "$mount"; then return 1; fi
    ACTIVE_MIGRATION_MOUNT=""
    {
        printf 'format=1\ntransport=sparsebundle\ncreated_at=%s\n' "$MIGRATION_PACKAGE_CREATED"
        printf 'app_name=%s\nbundle_id=%s\ntotal_bytes=%s\n' "$(encode_field "$MIGRATION_PACKAGE_NAME")" "$(encode_field "$MIGRATION_PACKAGE_ID")" "$MIGRATION_PACKAGE_BYTES"
    } > "$sidecar" || { APPOFFLOAD_ERROR="The sparsebundle was created but could not be cataloged."; ACTIVE_MIGRATION_NETWORK_BUNDLE=""; return 1; }
    ACTIVE_MIGRATION_NETWORK_BUNDLE=""; clear_active_transaction; LAST_MIGRATION_BACKUP="$bundle"
}

migration_remove_backup_files() {
    local source="$1"
    if migration_native_backup_safe "$source"; then
        [ -d "$source" ] && [ ! -L "$source" ] || { APPOFFLOAD_ERROR="Native migration backup is unavailable or unsafe."; return 1; }
        /bin/rm -rf "$source"
    elif migration_network_bundle_safe "$source"; then
        [ -d "$source" ] && [ ! -L "$source" ] || { APPOFFLOAD_ERROR="Network migration bundle is unavailable or unsafe."; return 1; }
        /bin/rm -rf "$source"
        /bin/rm -f "$source.appoffload.conf"
    else
        APPOFFLOAD_ERROR="Safety guard refused the migration backup path."
        return 1
    fi
}

move_app_migration_backup() {
    local source="$1" target="$2" kind package result new_backup
    APPOFFLOAD_ERROR=""; LAST_MIGRATION_BACKUP=""; LAST_EXTERNAL_BYTES=0
    [ -d "$target" ] && [ -w "$target" ] || { APPOFFLOAD_ERROR="Target is not a mounted writable directory: $target"; return 1; }
    if [ "${APPOFFLOAD_ALLOW_ANY_TARGET:-0}" != "1" ]; then case "$target" in "$VOLUMES_ROOT"/*) ;; *) APPOFFLOAD_ERROR="Target must be mounted below $VOLUMES_ROOT"; return 1 ;; esac; fi
    migration_open_backup_source "$source" || return 1; package="$MIGRATION_OPEN_PACKAGE"
    migration_read_package_info "$package" || { migration_close_backup_source; return 1; }
    kind=$(migration_target_kind "$target"); acquire_lock || { migration_close_backup_source; return 1; }
    case "$kind" in native) migration_copy_package_native "$package" "$target"; result=$? ;; network) migration_copy_package_network "$package" "$target"; result=$? ;; *) APPOFFLOAD_ERROR="Unsupported migration target filesystem: $(migration_filesystem_personality "$target")"; result=1 ;; esac
    if [ "$result" -ne 0 ]; then release_lock; migration_close_backup_source; return 1; fi
    new_backup="$LAST_MIGRATION_BACKUP"; migration_close_backup_source
    if ! migration_remove_backup_files "$source"; then release_lock; LAST_MIGRATION_BACKUP="$new_backup"; APPOFFLOAD_ERROR="The verified destination exists at $new_backup, but the original could not be removed."; return 1; fi
    release_lock; LAST_MIGRATION_BACKUP="$new_backup"; LAST_EXTERNAL_BYTES="$MIGRATION_PACKAGE_BYTES"; LAST_MIGRATION_APP_NAME="$MIGRATION_PACKAGE_NAME"
}

delete_app_migration_backup() {
    local source="$1" sidecar
    APPOFFLOAD_ERROR=""; LAST_EXTERNAL_BYTES=0; LAST_MIGRATION_APP_NAME=""
    if migration_native_backup_safe "$source"; then
        [ -f "$source/metadata.conf" ] || { APPOFFLOAD_ERROR="Migration backup metadata is missing."; return 1; }
        migration_read_package_info "$source" || return 1
    elif migration_network_bundle_safe "$source"; then
        sidecar="$source.appoffload.conf"; [ -f "$sidecar" ] || { APPOFFLOAD_ERROR="Network migration catalog metadata is missing."; return 1; }
        MIGRATION_PACKAGE_NAME=$(decode_field "$(/usr/bin/awk -F= '$1 == "app_name" {print substr($0,index($0,"=")+1);exit}' "$sidecar")")
        MIGRATION_PACKAGE_BYTES=$(/usr/bin/awk -F= '$1 == "total_bytes" {print $2;exit}' "$sidecar")
        case "$MIGRATION_PACKAGE_BYTES" in ''|*[!0-9]*) APPOFFLOAD_ERROR="Network migration size metadata is invalid."; return 1 ;; esac
    else
        APPOFFLOAD_ERROR="Safety guard refused the migration backup path."
        return 1
    fi
    ensure_not_in_use "$source" || return 1
    acquire_lock || return 1
    if ! migration_remove_backup_files "$source"; then release_lock; return 1; fi
    release_lock; LAST_EXTERNAL_BYTES="$MIGRATION_PACKAGE_BYTES"; LAST_MIGRATION_APP_NAME="$MIGRATION_PACKAGE_NAME"
}

verify_app_migration_backup() {
    local backup="$1" expected actual workdir
    APPOFFLOAD_ERROR=""
    [ -d "$backup/payload" ] && [ -f "$backup/metadata.conf" ] && [ -f "$backup/items.tsv" ] && [ -f "$backup/checksums.tsv" ] || { APPOFFLOAD_ERROR="Not a complete AppSupport Offload migration backup: $backup"; return 1; }
    [ "$(/usr/bin/awk -F= '$1 == "format" {print $2;exit}' "$backup/metadata.conf")" = "1" ] || { APPOFFLOAD_ERROR="Unsupported migration backup format."; return 1; }
    [ "$(/usr/bin/awk -F= '$1 == "status" {print $2;exit}' "$backup/metadata.conf")" = "complete" ] || { APPOFFLOAD_ERROR="Migration backup is not marked complete."; return 1; }
    workdir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/appoffload-migration-verify.XXXXXX") || return 1
    actual="$workdir/checksums.tsv"; create_manifest "$backup/payload" "$actual" || { /bin/rm -rf "$workdir"; return 1; }
    expected="$backup/checksums.tsv"
    if ! /usr/bin/cmp -s "$expected" "$actual"; then /bin/rm -rf "$workdir"; APPOFFLOAD_ERROR="Migration backup checksum verification failed."; return 1; fi
    /bin/rm -rf "$workdir"
}

restore_app_migration_backup() {
    local backup="$1" app_target_root="${2:-}" metadata items original_app app_name total free required stage workdir transaction_id
    local category encoded_relative encoded_source size relative target staged index=0 count committed_file actual_count
    APPOFFLOAD_ERROR=""; LAST_LOCAL_DELTA_BYTES=0; LAST_EXTERNAL_BYTES=0; LAST_MIGRATION_APP_NAME=""; LAST_MIGRATION_ITEM_COUNT=0
    verify_app_migration_backup "$backup" || return 1
    metadata="$backup/metadata.conf"; items="$backup/items.tsv"
    app_name=$(decode_field "$(/usr/bin/awk -F= '$1 == "app_name" {print substr($0,index($0,"=")+1);exit}' "$metadata")")
    original_app=$(decode_field "$(/usr/bin/awk -F= '$1 == "original_app_path" {print substr($0,index($0,"=")+1);exit}' "$metadata")")
    total=$(/usr/bin/awk -F= '$1 == "total_bytes" {print $2;exit}' "$metadata"); count=$(/usr/bin/awk -F= '$1 == "item_count" {print $2;exit}' "$metadata")
    case "$total:$count" in *[!0-9:]*|:*|*:) APPOFFLOAD_ERROR="Migration backup metadata is invalid."; return 1 ;; esac
    actual_count=$(/usr/bin/awk 'END {print NR+0}' "$items")
    [ "$count" -gt 0 ] && [ "$actual_count" -eq "$count" ] || { APPOFFLOAD_ERROR="Migration backup item count is invalid."; return 1; }
    if [ -z "$app_target_root" ]; then case "$original_app" in /Applications/*) app_target_root="/Applications" ;; *) app_target_root="$USER_APPLICATIONS_ROOT" ;; esac; fi
    case "$app_target_root" in /*) ;; *) APPOFFLOAD_ERROR="App restore target must be an absolute path."; return 1 ;; esac
    acquire_lock || return 1
    free=$(available_bytes "$USER_LIBRARY_ROOT"); required=$((total + total / 20 + 67108864))
    [ -n "$free" ] && [ "$free" -ge "$required" ] || { APPOFFLOAD_ERROR="Not enough local space: need $(human_bytes "$required"), have $(human_bytes "${free:-0}")."; release_lock; return 1; }
    while IFS=$'\t' read -r category encoded_relative encoded_source size; do
        relative=$(decode_field "$encoded_relative"); migration_safe_relative "$relative" || { APPOFFLOAD_ERROR="Backup contains an unsafe restore path."; release_lock; return 1; }
        case "$category" in App) case "$relative" in */*) APPOFFLOAD_ERROR="Backup contains an unsafe app path."; release_lock; return 1 ;; esac; target="$app_target_root/$relative" ;; Library) target="$USER_LIBRARY_ROOT/$relative" ;; *) APPOFFLOAD_ERROR="Backup contains an unknown item category."; release_lock; return 1 ;; esac
        if [ -e "$target" ] || [ -L "$target" ]; then APPOFFLOAD_ERROR="Restore refused to overwrite existing item: $target"; release_lock; return 1; fi
    done < "$items"
    transaction_id="$(/bin/date +%Y%m%d-%H%M%S)-$$"; stage="$USER_LIBRARY_ROOT/.appoffload-staging-migration-restore-$transaction_id"; workdir="${TMPDIR:-/tmp}/appoffload-migration-restore-$transaction_id"; committed_file="$workdir/committed"
    /bin/mkdir -p "$stage" "$workdir" || { APPOFFLOAD_ERROR="Could not create local restore staging."; release_lock; return 1; }
    ACTIVE_SOURCE="$backup" ACTIVE_STAGE="$stage" ACTIVE_WORKDIR="$workdir" ACTIVE_PHASE="migration-restore"
    ACTIVE_MIGRATION_COMMITTED_FILE="$committed_file"
    emit_progress "Restoring app backup" 5 "Copying verified package to local staging"
    copy_with_progress "$backup/payload" "$stage/payload" "$total" || { rollback_active_transaction; return 1; }
    migration_verify_pair "$backup/payload" "$stage/payload" "$workdir" "restore" || { rollback_active_transaction; return 1; }
    : > "$committed_file"
    while IFS=$'\t' read -r category encoded_relative encoded_source size; do
        relative=$(decode_field "$encoded_relative"); staged="$stage/payload/$category/$relative"
        case "$category" in App) target="$app_target_root/$relative" ;; Library) target="$USER_LIBRARY_ROOT/$relative" ;; esac
        /bin/mkdir -p "$(/usr/bin/dirname "$target")" || { APPOFFLOAD_ERROR="Could not create restore parent for $target"; break; }
        emit_progress "Activating restored app" "$((85 + (index + 1) * 14 / count))" "$((index + 1)) of $count: $relative"
        if [ -e "$target" ] || [ -L "$target" ]; then APPOFFLOAD_ERROR="Restore collision appeared during commit: $target"; break; fi
        if /bin/mv "$staged" "$target"; then index=$((index + 1)); printf '%s\t%s\n' "$(encode_field "$target")" "$(encode_field "$staged")" >> "$committed_file"; else APPOFFLOAD_ERROR="Could not activate restored item: $target"; break; fi
    done < "$items"
    if [ "$index" -ne "$count" ]; then
        rollback_active_transaction
        return 1
    fi
    ACTIVE_MIGRATION_COMMITTED_FILE=""; ACTIVE_STAGE=""; /bin/rm -rf "$stage" "$workdir"; release_lock; clear_active_transaction
    LAST_LOCAL_DELTA_BYTES=$((0 - total)); LAST_EXTERNAL_BYTES=$total; LAST_MIGRATION_APP_NAME="$app_name"; LAST_MIGRATION_ITEM_COUNT=$count
    emit_progress "Complete" 100 "$count items restored"
}

rollback_migration_commits() {
    local encoded_target encoded_staged target staged
    [ -n "$ACTIVE_MIGRATION_COMMITTED_FILE" ] && [ -f "$ACTIVE_MIGRATION_COMMITTED_FILE" ] || return 0
    while IFS=$'\t' read -r encoded_target encoded_staged; do
        target=$(decode_field "$encoded_target"); staged=$(decode_field "$encoded_staged")
        if [ -e "$target" ] || [ -L "$target" ]; then
            /bin/mkdir -p "$(/usr/bin/dirname "$staged")" 2>/dev/null || true
            /bin/mv "$target" "$staged" 2>/dev/null || true
        fi
    done < "$ACTIVE_MIGRATION_COMMITTED_FILE"
    ACTIVE_MIGRATION_COMMITTED_FILE=""
}

rollback_migration_mount() {
    local bundle="$ACTIVE_MIGRATION_NETWORK_BUNDLE"
    if [ -n "$ACTIVE_MIGRATION_MOUNT" ]; then
        "$HDIUTIL_BIN" detach "$ACTIVE_MIGRATION_MOUNT" >/dev/null 2>&1 || true
    fi
    ACTIVE_MIGRATION_MOUNT=""
    if [ -n "$bundle" ] && migration_network_bundle_safe "$bundle" && [ ! -f "$bundle.appoffload.conf" ]; then
        /bin/rm -rf "$bundle"
    fi
    ACTIVE_MIGRATION_NETWORK_BUNDLE=""
}
