#!/bin/bash

# Core transaction engine for appoffload. Compatible with macOS Bash 3.2.

APP_SUPPORT_ROOT="${APPOFFLOAD_APP_SUPPORT_ROOT:-$HOME/Library/Application Support}"
VOLUMES_ROOT="${APPOFFLOAD_VOLUMES_ROOT:-/Volumes}"
APPLICATION_ROOTS_OVERRIDE="${APPOFFLOAD_APPLICATION_ROOTS:-}"
CONFIG_DIR="${APPOFFLOAD_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/appoffload}"
APP_ROOTS_FILE="$CONFIG_DIR/app-roots"
OFFLOAD_REGISTRY_FILE="$CONFIG_DIR/offloads.tsv"
PREFERENCES_ROOT="${APPOFFLOAD_PREFERENCES_ROOT:-$HOME/Library/Preferences}"
SAVED_STATE_ROOT="${APPOFFLOAD_SAVED_STATE_ROOT:-$HOME/Library/Saved Application State}"
MANAGED_DIR_NAME=".AppSupportOffload"
APPOFFLOAD_ERROR=""
LAST_LOCAL_DELTA_BYTES=0
LAST_EXTERNAL_BYTES=0
LAST_APP_ROOT=""
ACTIVE_PHASE=""
ACTIVE_SOURCE=""
ACTIVE_BACKUP=""
ACTIVE_STAGE=""
ACTIVE_STAGE_ID=""
ACTIVE_FINAL=""
ACTIVE_WORKDIR=""
ACTIVE_COPY_PID=""
ACTIVE_LINK_ROLLBACK=""
ACTIVE_JOURNAL=""
ACTIVE_OLD_DESTINATION=""
ACTIVE_OPERATION=""
LOCK_DIR=""
REGISTRY_SOURCE=""
REGISTRY_DESTINATION=""
REGISTRY_VOLUME_ID=""
REGISTRY_VOLUME_ROOT=""
REGISTRY_RELATIVE_PATH=""

emit_progress() {
    local phase="$1" percent="$2" detail="${3:-}"
    if type ui_progress >/dev/null 2>&1; then
        ui_progress "$phase" "$percent" "$detail"
    elif [ -t 1 ]; then
        printf '\r%-24s [%3s%%] %-36s' "$phase" "$percent" "$detail"
        [ "$percent" = "100" ] && printf '\n'
    fi
}

new_transaction_id() {
    printf '%s-%s-%s\n' "$(/bin/date +%Y%m%d-%H%M%S)" "$$" "$RANDOM"
}

human_bytes() {
    awk -v bytes="$1" 'BEGIN {
        split("B KB MB GB TB PB", unit, " "); i=1
        while (bytes >= 1000 && i < 6) { bytes /= 1000; i++ }
        if (i == 1) printf "%d %s", bytes, unit[i]
        else printf "%.1f %s", bytes, unit[i]
    }'
}

path_bytes() {
    local path="$1" blocks
    # du can report a usable subtotal while returning nonzero for one unreadable
    # child. A missing or malformed total is still an error.
    blocks=$(/usr/bin/du -sk "$path" 2>/dev/null) || true
    blocks=${blocks%%[[:space:]]*}
    case "$blocks" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' "$((blocks * 1024))"
}

directory_identity() {
    [ -d "$1" ] && [ ! -L "$1" ] || return 1
    /usr/bin/stat -f '%d:%i' "$1" 2>/dev/null
}

available_bytes() {
    /bin/df -Pk "$1" 2>/dev/null | /usr/bin/awk 'NR == 2 { printf "%.0f\n", $4 * 1024 }'
}

encode_field() {
    printf '%s' "$1" | /usr/bin/base64 | /usr/bin/tr -d '\n'
}

decode_field() {
    printf '%s' "$1" | /usr/bin/base64 -D 2>/dev/null
}

volume_identity() {
    local volume="$1" identity device
    if [ -f "$volume/.appoffload-volume-id" ]; then
        identity=$(/usr/bin/head -n 1 "$volume/.appoffload-volume-id" 2>/dev/null)
        [ -n "$identity" ] && { printf 'test:%s\n' "$identity"; return; }
    fi
    identity=$(/usr/sbin/diskutil info "$volume" 2>/dev/null | /usr/bin/awk -F ': *' '/Volume UUID/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')
    if [ -n "$identity" ]; then
        printf 'uuid:%s\n' "$identity"
        return
    fi
    device=$(/bin/df -Pk "$volume" 2>/dev/null | /usr/bin/awk 'NR == 2 {print $1}')
    [ -n "$device" ] && printf 'device:%s\n' "$device"
}

volume_root_for_destination() {
    local destination="$1" volume physical
    for volume in "$VOLUMES_ROOT"/*; do
        [ -d "$volume" ] || continue
        physical=$(cd "$volume" 2>/dev/null && pwd -P) || continue
        case "$destination" in "$physical"/*|"$volume"/*) printf '%s\n' "$physical"; return 0 ;; esac
    done
    return 1
}

find_volume_by_identity() {
    local wanted="$1" volume identity
    [ -n "$wanted" ] || return 1
    for volume in "$VOLUMES_ROOT"/*; do
        [ -d "$volume" ] || continue
        identity=$(volume_identity "$volume")
        if [ "$identity" = "$wanted" ]; then
            cd "$volume" 2>/dev/null && pwd -P
            return
        fi
    done
    return 1
}

lookup_offload_record() {
    local wanted="$1" encoded_source encoded_destination encoded_id encoded_root encoded_relative recorded source
    REGISTRY_SOURCE="" REGISTRY_DESTINATION="" REGISTRY_VOLUME_ID="" REGISTRY_VOLUME_ROOT="" REGISTRY_RELATIVE_PATH=""
    [ -f "$OFFLOAD_REGISTRY_FILE" ] || return 1
    while IFS=$'\t' read -r encoded_source encoded_destination encoded_id encoded_root encoded_relative recorded; do
        [ -n "$encoded_source" ] || continue
        source=$(decode_field "$encoded_source")
        [ "$source" = "$wanted" ] || continue
        REGISTRY_SOURCE="$source"
        REGISTRY_DESTINATION=$(decode_field "$encoded_destination")
        REGISTRY_VOLUME_ID=$(decode_field "$encoded_id")
        REGISTRY_VOLUME_ROOT=$(decode_field "$encoded_root")
        REGISTRY_RELATIVE_PATH=$(decode_field "$encoded_relative")
        return 0
    done < "$OFFLOAD_REGISTRY_FILE"
    return 1
}

register_offload() {
    local source="$1" destination="$2" volume_root="${3:-}" identity relative temp a b c d e f
    [ -n "$volume_root" ] || volume_root=$(volume_root_for_destination "$destination" 2>/dev/null || true)
    [ -n "$volume_root" ] || return 1
    identity=$(volume_identity "$volume_root")
    [ -n "$identity" ] || return 1
    case "$destination" in "$volume_root"/*) relative=${destination#"$volume_root"/} ;; *) return 1 ;; esac
    /bin/mkdir -p "$CONFIG_DIR" || return 1
    temp=$(/usr/bin/mktemp "$CONFIG_DIR/.offloads.XXXXXX") || return 1
    if [ -f "$OFFLOAD_REGISTRY_FILE" ]; then
        while IFS=$'\t' read -r a b c d e f; do
            [ -n "$a" ] || continue
            [ "$(decode_field "$a")" = "$source" ] || printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$a" "$b" "$c" "$d" "$e" "$f" >> "$temp"
        done < "$OFFLOAD_REGISTRY_FILE"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(encode_field "$source")" "$(encode_field "$destination")" "$(encode_field "$identity")" \
        "$(encode_field "$volume_root")" "$(encode_field "$relative")" "$(/bin/date +%s)" >> "$temp"
    /bin/chmod 600 "$temp"
    /bin/mv "$temp" "$OFFLOAD_REGISTRY_FILE"
}

remove_offload_record() {
    local source="$1" temp a b c d e f found=0
    APPOFFLOAD_ERROR=""
    [ -f "$OFFLOAD_REGISTRY_FILE" ] || { APPOFFLOAD_ERROR="No health record exists for: $source"; return 1; }
    temp=$(/usr/bin/mktemp "$CONFIG_DIR/.offloads.XXXXXX") || return 1
    while IFS=$'\t' read -r a b c d e f; do
        [ -n "$a" ] || continue
        if [ "$(decode_field "$a")" = "$source" ]; then found=1; else printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$a" "$b" "$c" "$d" "$e" "$f" >> "$temp"; fi
    done < "$OFFLOAD_REGISTRY_FILE"
    if [ "$found" -ne 1 ]; then
        /bin/rm -f "$temp"
        APPOFFLOAD_ERROR="No health record exists for: $source"
        return 1
    fi
    /bin/chmod 600 "$temp"
    /bin/mv "$temp" "$OFFLOAD_REGISTRY_FILE" || { APPOFFLOAD_ERROR="Could not update the health registry."; return 1; }
}

sync_offload_registry() {
    local source destination volume_root
    [ -d "$APP_SUPPORT_ROOT" ] || return 0
    for source in "$APP_SUPPORT_ROOT"/*; do
        [ -L "$source" ] || continue
        destination=$(managed_link_destination "$source" 2>/dev/null || true)
        [ -d "$destination" ] || continue
        lookup_offload_record "$source" && continue
        volume_root=$(volume_root_for_destination "$destination" 2>/dev/null || true)
        [ -n "$volume_root" ] && register_offload "$source" "$destination" "$volume_root" >/dev/null 2>&1 || true
    done
}

is_managed_destination() {
    case "$1" in
        "$VOLUMES_ROOT"/*/"$MANAGED_DIR_NAME"/*/Application\ Support/*) return 0 ;;
        *)
            [ "${APPOFFLOAD_ALLOW_ANY_TARGET:-0}" = "1" ] && case "$1" in
                */"$MANAGED_DIR_NAME"/*/Application\ Support/*) return 0 ;;
            esac
            return 1
            ;;
    esac
}

managed_link_destination() {
    local source="$1" raw destination
    [ -L "$source" ] || return 1
    raw=$(/usr/bin/readlink "$source") || return 1
    case "$raw" in
        /*) destination="$raw" ;;
        *) destination="$(cd "$(/usr/bin/dirname "$source")" && pwd -P)/$raw" ;;
    esac
    if [ -d "$destination" ]; then
        destination=$(cd "$destination" && pwd -P) || return 1
    fi
    is_managed_destination "$destination" || return 1
    printf '%s\n' "$destination"
}

is_application_support_child() {
    local path="$1" parent root
    parent=$(cd "$(/usr/bin/dirname "$path")" 2>/dev/null && pwd -P) || return 1
    root=$(cd "$APP_SUPPORT_ROOT" 2>/dev/null && pwd -P) || return 1
    [ "$parent" = "$root" ]
}

list_external_volumes() {
    local volume
    [ -d "$VOLUMES_ROOT" ] || return 0
    for volume in "$VOLUMES_ROOT"/*; do
        [ -d "$volume" ] || continue
        [ -w "$volume" ] || continue
        printf '%s\t%s\n' "$(available_bytes "$volume")" "$volume"
    done
}

list_folders() {
    local item size status destination
    [ -d "$APP_SUPPORT_ROOT" ] || return 0
    for item in "$APP_SUPPORT_ROOT"/*; do
        [ -e "$item" ] || [ -L "$item" ] || continue
        if destination=$(managed_link_destination "$item" 2>/dev/null); then
            size=$(path_bytes "$destination" 2>/dev/null || echo 0)
            status="offloaded"
        elif [ -d "$item" ] && [ ! -L "$item" ]; then
            size=$(path_bytes "$item" 2>/dev/null || echo 0)
            status="local"
        else
            continue
        fi
        printf '%s\t%s\t%s\n' "$size" "$status" "$item"
    done
}

normalize_identity() {
    printf '%s' "$1" | /usr/bin/tr '[:upper:]' '[:lower:]' | /usr/bin/tr -cd '[:alnum:]'
}

plist_value() {
    local plist="$1" key="$2"
    /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null | /usr/bin/head -n 1
}

default_app_roots() {
    printf '%s\n' "/Applications" "$HOME/Applications" "/System/Applications"
}

custom_app_roots() {
    [ -f "$APP_ROOTS_FILE" ] || return 0
    while IFS= read -r root || [ -n "$root" ]; do
        [ -n "$root" ] || continue
        case "$root" in \#*) continue ;; esac
        printf '%s\n' "$root"
    done < "$APP_ROOTS_FILE"
}

configured_app_roots() {
    local roots root
    {
        if [ -n "$APPLICATION_ROOTS_OVERRIDE" ]; then
            roots="$APPLICATION_ROOTS_OVERRIDE"
            while [ -n "$roots" ]; do
                case "$roots" in
                    *:*) root=${roots%%:*}; roots=${roots#*:} ;;
                    *) root=$roots; roots="" ;;
                esac
                [ -n "$root" ] && printf '%s\n' "$root"
            done
        else
            default_app_roots
        fi
        custom_app_roots
    } | /usr/bin/awk 'NF && !seen[$0]++'
}

list_app_roots() {
    local root status
    default_app_roots | while IFS= read -r root; do
        [ -d "$root" ] && status="available" || status="unavailable"
        printf 'default\t%s\t%s\n' "$status" "$root"
    done
    custom_app_roots | while IFS= read -r root; do
        [ -d "$root" ] && status="available" || status="unavailable"
        printf 'custom\t%s\t%s\n' "$status" "$root"
    done
}

add_app_root() {
    local requested="$1" root temp existing
    APPOFFLOAD_ERROR=""
    LAST_APP_ROOT=""
    case "$requested" in
        "~") requested="$HOME" ;;
        "~/"*) requested="$HOME/${requested:2}" ;;
    esac
    case "$requested" in
        /*) ;;
        *) APPOFFLOAD_ERROR="App search location must be an absolute path."; return 1 ;;
    esac
    case "$requested" in *$'\n'*|*$'\r'*|*$'\t'*) APPOFFLOAD_ERROR="App search location contains an invalid control character."; return 1 ;; esac
    [ -d "$requested" ] || { APPOFFLOAD_ERROR="Folder does not exist: $requested"; return 1; }
    root=$(cd "$requested" 2>/dev/null && pwd -P) || { APPOFFLOAD_ERROR="Folder cannot be read: $requested"; return 1; }
    existing=$(configured_app_roots | /usr/bin/awk -v root="$root" '$0 == root {print; exit}')
    [ -z "$existing" ] || { APPOFFLOAD_ERROR="Location is already configured: $root"; return 1; }
    /bin/mkdir -p "$CONFIG_DIR" || { APPOFFLOAD_ERROR="Could not create configuration folder: $CONFIG_DIR"; return 1; }
    temp=$(/usr/bin/mktemp "$CONFIG_DIR/.app-roots.XXXXXX") || { APPOFFLOAD_ERROR="Could not create a configuration update."; return 1; }
    custom_app_roots > "$temp"
    printf '%s\n' "$root" >> "$temp"
    LC_ALL=C /usr/bin/sort -u "$temp" -o "$temp"
    /bin/chmod 600 "$temp"
    /bin/mv "$temp" "$APP_ROOTS_FILE" || { /bin/rm -f "$temp"; APPOFFLOAD_ERROR="Could not save the app search location."; return 1; }
    LAST_APP_ROOT="$root"
    printf '%s\n' "$root"
}

remove_app_root() {
    local requested="$1" root temp found=0 item
    APPOFFLOAD_ERROR=""
    root="$requested"
    [ -d "$requested" ] && root=$(cd "$requested" 2>/dev/null && pwd -P)
    [ -f "$APP_ROOTS_FILE" ] || { APPOFFLOAD_ERROR="No custom app search locations are configured."; return 1; }
    temp=$(/usr/bin/mktemp "$CONFIG_DIR/.app-roots.XXXXXX") || { APPOFFLOAD_ERROR="Could not create a configuration update."; return 1; }
    : > "$temp"
    while IFS= read -r item || [ -n "$item" ]; do
        [ -n "$item" ] || continue
        if [ "$item" = "$root" ]; then found=1; else printf '%s\n' "$item" >> "$temp"; fi
    done < "$APP_ROOTS_FILE"
    if [ "$found" -ne 1 ]; then
        /bin/rm -f "$temp"
        APPOFFLOAD_ERROR="Custom location is not configured: $root"
        return 1
    fi
    /bin/chmod 600 "$temp"
    /bin/mv "$temp" "$APP_ROOTS_FILE" || { /bin/rm -f "$temp"; APPOFFLOAD_ERROR="Could not save the location removal."; return 1; }
}

build_installed_app_index() {
    local output="$1" root app plist identifier display bundle_name executable key
    : > "$output" || return 1
    while IFS= read -r root; do
        [ -d "$root" ] || continue
        while IFS= read -r -d '' app; do
            plist="$app/Contents/Info.plist"
            [ -f "$plist" ] || continue
            identifier=$(plist_value "$plist" CFBundleIdentifier)
            display=$(plist_value "$plist" CFBundleDisplayName)
            bundle_name=$(plist_value "$plist" CFBundleName)
            executable=$(plist_value "$plist" CFBundleExecutable)
            [ -n "$display" ] || display=$bundle_name
            [ -n "$display" ] || display=$(/usr/bin/basename "$app" .app)
            display=$(printf '%s' "$display" | /usr/bin/tr '\t\r\n' '   ')
            app=$(printf '%s' "$app" | /usr/bin/tr '\t\r\n' '   ')
            if [ -n "$identifier" ]; then
                key=$(printf '%s' "$identifier" | /usr/bin/tr '[:upper:]' '[:lower:]')
                printf '%s\tid\t%s\t%s\n' "$key" "$display" "$app" >> "$output"
            fi
            for key in "$display" "$bundle_name" "$executable"; do
                [ -n "$key" ] || continue
                key=$(normalize_identity "$key")
                [ -n "$key" ] && printf '%s\tname\t%s\t%s\n' "$key" "$display" "$app" >> "$output"
            done
        done < <(/usr/bin/find "$root" -type d -name '*.app' -prune -print0 2>/dev/null)
    done < <(configured_app_roots)
    LC_ALL=C /usr/bin/sort -u "$output" -o "$output"
}

folder_has_uninstall_evidence() {
    local name="$1"
    [ -e "$PREFERENCES_ROOT/$name.plist" ] || [ -e "$SAVED_STATE_ROOT/$name.savedState" ]
}

# Output fields: allocated bytes, classification, matched app/evidence, folder path.
# "recommend" is intentionally conservative: it requires a reverse-domain-style
# folder name, no installed bundle-ID match, and a surviving preference/state file.
audit_folders() {
    local workdir index size location path name id_key name_key match related classification evidence
    workdir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/appoffload-audit.XXXXXX") || return 1
    index="$workdir/apps.tsv"
    build_installed_app_index "$index" || { /bin/rm -rf "$workdir"; return 1; }
    while IFS=$'\t' read -r size location path; do
        [ -n "$path" ] || continue
        name=$(/usr/bin/basename "$path")
        if [ "$location" = "offloaded" ]; then
            printf '%s\toffloaded\tmanaged external copy\t%s\n' "$size" "$path"
            continue
        fi
        id_key=$(printf '%s' "$name" | /usr/bin/tr '[:upper:]' '[:lower:]')
        name_key=$(normalize_identity "$name")
        match=$(/usr/bin/awk -F '\t' -v id="$id_key" -v name="$name_key" '
            ($2 == "id" && $1 == id) || ($2 == "name" && $1 == name) { print $3; exit }
        ' "$index")
        if [ -n "$match" ]; then
            classification="installed"
            evidence="$match"
        elif [[ "$id_key" == com.apple.* || "$id_key" == group.com.apple.* ]]; then
            classification="system"
            evidence="macOS-managed component"
        else
            related=$(/usr/bin/awk -F '\t' -v id="$id_key" '
                $2 == "id" && (index(id, $1 ".") == 1 || index($1, id ".") == 1) { print $3; exit }
            ' "$index")
            if [ -n "$related" ]; then
                classification="related"
                evidence="related installed app: $related"
            elif [ "$size" -gt 0 ] && [[ "$name" =~ ^[[:alnum:]_-]+(\.[[:alnum:]_-]+){2,}$ ]] && folder_has_uninstall_evidence "$name"; then
                classification="recommend"
                evidence="no matching app; leftover preference/state evidence"
            else
                classification="review"
                evidence="no reliable app match"
            fi
        fi
        printf '%s\t%s\t%s\t%s\n' "$size" "$classification" "$evidence" "$path"
    done < <(list_folders)
    /bin/rm -rf "$workdir"
}

absolute_link_destination() {
    local source="$1" raw destination
    [ -L "$source" ] || return 1
    raw=$(/usr/bin/readlink "$source") || return 1
    case "$raw" in
        /*) destination="$raw" ;;
        *) destination="$(cd "$(/usr/bin/dirname "$source")" 2>/dev/null && pwd -P)/$raw" ;;
    esac
    printf '%s\n' "$destination"
}

same_destination() {
    local first="$1" second="$2"
    [ -n "$first" ] && [ -n "$second" ] || return 1
    if [ -d "$first" ]; then first=$(cd "$first" 2>/dev/null && pwd -P) || return 1; fi
    if [ -d "$second" ]; then second=$(cd "$second" 2>/dev/null && pwd -P) || return 1; fi
    [ "$first" = "$second" ]
}

health_scan() {
    local a b c d e recorded source destination identity volume_root relative name current mounted candidate detail
    local volume stage journal phase backup base rest recovered_source user_name managed_root candidate bundle
    sync_offload_registry
    if [ -f "$OFFLOAD_REGISTRY_FILE" ]; then
        while IFS=$'\t' read -r a b c d e recorded; do
            [ -n "$a" ] || continue
            source=$(decode_field "$a")
            destination=$(decode_field "$b")
            identity=$(decode_field "$c")
            volume_root=$(decode_field "$d")
            relative=$(decode_field "$e")
            name=$(/usr/bin/basename "$source")
            if [ -L "$source" ]; then
                current=$(absolute_link_destination "$source" 2>/dev/null || true)
                if [ -d "$current" ]; then
                    if [ "$current" != "$destination" ]; then
                        mounted=$(volume_root_for_destination "$current" 2>/dev/null || true)
                        [ -n "$mounted" ] && register_offload "$source" "$(cd "$current" && pwd -P)" "$mounted" >/dev/null 2>&1 || true
                    fi
                    printf 'ok\thealthy\t%s\t%s\t%s\tActive and reachable\tnone\n' "$name" "$source" "$current"
                    continue
                fi
            elif [ -d "$source" ]; then
                printf 'warning\tstale-record\t%s\t%s\t%s\tFolder is local; registry entry is stale\tforget-record\n' "$name" "$source" "$destination"
                continue
            elif [ -e "$source" ]; then
                printf 'critical\tpath-conflict\t%s\t%s\t%s\tExpected link path is occupied by another item\tnone\n' "$name" "$source" "$destination"
                continue
            fi
            mounted=$(find_volume_by_identity "$identity" 2>/dev/null || true)
            if [ -n "$mounted" ]; then
                candidate="$mounted/$relative"
                if [ -d "$candidate" ]; then
                    if [ -L "$source" ]; then detail="Target volume was renamed or remounted"; else detail="Managed link is missing but data is available"; fi
                    printf 'warning\trepairable-link\t%s\t%s\t%s\t%s\trepair-link\n' "$name" "$source" "$candidate" "$detail"
                else
                    printf 'critical\tmissing-data\t%s\t%s\t%s\tTracked disk is mounted but managed data is missing\tnone\n' "$name" "$source" "$candidate"
                fi
            else
                printf 'warning\tdisk-missing\t%s\t%s\t%s\tTracked target disk is not mounted\tnone\n' "$name" "$source" "$destination"
            fi
        done < "$OFFLOAD_REGISTRY_FILE"
    fi

    user_name=${USER:-$(/usr/bin/id -un)}
    for volume in "$VOLUMES_ROOT"/*; do
        [ -d "$volume" ] || continue
        managed_root="$volume/$MANAGED_DIR_NAME/$user_name/Application Support"
        for stage in "$managed_root"/.appoffload-staging-*; do
            [ -e "$stage" ] || continue
            printf 'warning\tstale-staging\t%s\t%s\t%s\tIncomplete staging copy can be removed\tclean-staging\n' "$(/usr/bin/basename "$stage")" "$stage" "$stage"
        done
        for candidate in "$managed_root"/*; do
            [ -d "$candidate" ] && [ ! -L "$candidate" ] || continue
            name=$(/usr/bin/basename "$candidate")
            source="$APP_SUPPORT_ROOT/$name"
            current=$(managed_link_destination "$source" 2>/dev/null || true)
            same_destination "$current" "$candidate" && continue
            if lookup_offload_record "$source" && same_destination "$REGISTRY_DESTINATION" "$candidate"; then continue; fi
            printf 'warning\tuntracked-copy\t%s\t%s\t%s\tManaged copy has no active link or health record; review manually\tnone\n' "$name" "$candidate" "$candidate"
        done
        for journal in "$volume/$MANAGED_DIR_NAME/.transactions"/*.state; do
            [ -f "$journal" ] || continue
            phase=$(/usr/bin/awk -F= '$1 == "phase" {print $2; exit}' "$journal")
            case "$phase" in complete|recovered|aborted) continue ;; esac
            printf 'warning\tincomplete-transaction\t%s\t%s\t%s\tTransaction stopped during phase: %s\trecover-transaction\n' "$(/usr/bin/basename "$journal")" "$journal" "$journal" "${phase:-unknown}"
        done
        for bundle in "$volume/$MANAGED_DIR_NAME/${APP_BACKUP_DIR_NAME:-App Backups}"/*/*.appmigration.sparsebundle; do
            [ -d "$bundle" ] && [ ! -f "$bundle.appoffload.conf" ] || continue
            printf 'warning\tuncataloged-backup\t%s\t%s\t%s\tSparsebundle has no catalog; unmount and review manually\tnone\n' "$(/usr/bin/basename "$bundle")" "$bundle" "$bundle"
        done
    done
    for backup in "$APP_SUPPORT_ROOT"/.*.appoffload-backup-*; do
        [ -e "$backup" ] || continue
        base=$(/usr/bin/basename "$backup")
        rest=${base#.}
        name=${rest%%.appoffload-backup-*}
        recovered_source="$APP_SUPPORT_ROOT/$name"
        if [ ! -e "$recovered_source" ] && [ ! -L "$recovered_source" ]; then
            printf 'critical\trecoverable-backup\t%s\t%s\t%s\tLocal rollback copy exists and original path is missing\trecover-backup\n' "$name" "$backup" "$recovered_source"
        else
            printf 'warning\tleftover-backup\t%s\t%s\t%s\tRollback copy remains; manual review recommended\tnone\n' "$name" "$backup" "$recovered_source"
        fi
    done
    for stage in "$APP_SUPPORT_ROOT"/.*.appoffload-restore-*; do
        [ -e "$stage" ] || continue
        printf 'warning\tstale-staging\t%s\t%s\t%s\tIncomplete local restore copy can be removed\tclean-staging\n' "$(/usr/bin/basename "$stage")" "$stage" "$stage"
    done
}

repair_offload_link() {
    local source="$1" mounted candidate name temporary_link
    APPOFFLOAD_ERROR=""
    lookup_offload_record "$source" || { APPOFFLOAD_ERROR="No health record exists for: $source"; return 1; }
    mounted=$(find_volume_by_identity "$REGISTRY_VOLUME_ID" 2>/dev/null || true)
    [ -n "$mounted" ] || { APPOFFLOAD_ERROR="The recorded target disk is not mounted."; return 1; }
    candidate="$mounted/$REGISTRY_RELATIVE_PATH"
    [ -d "$candidate" ] || { APPOFFLOAD_ERROR="Managed data was not found at: $candidate"; return 1; }
    if [ -d "$source" ] && [ ! -L "$source" ]; then
        APPOFFLOAD_ERROR="A real folder occupies the link path; it was not overwritten."
        return 1
    fi
    name=$(/usr/bin/basename "$source")
    temporary_link="$APP_SUPPORT_ROOT/.$name.appoffload-health-link-$$"
    /bin/ln -s "$candidate" "$temporary_link" || { APPOFFLOAD_ERROR="Could not create the repaired link."; return 1; }
    if [ -L "$source" ]; then
        /bin/mv -h "$temporary_link" "$source" || { /bin/unlink "$temporary_link" 2>/dev/null || true; APPOFFLOAD_ERROR="Could not replace the broken link."; return 1; }
    elif ! /bin/mv "$temporary_link" "$source"; then
        /bin/unlink "$temporary_link" 2>/dev/null || true
        APPOFFLOAD_ERROR="Could not restore the missing link."
        return 1
    fi
    [ "$(absolute_link_destination "$source")" = "$candidate" ] || { APPOFFLOAD_ERROR="Repaired-link validation failed."; return 1; }
    register_offload "$source" "$(cd "$candidate" && pwd -P)" "$mounted" >/dev/null 2>&1 || true
}

is_health_staging_path() {
    case "$1" in
        "$VOLUMES_ROOT"/*/"$MANAGED_DIR_NAME"/*/Application\ Support/.appoffload-staging-*) return 0 ;;
        *)
            [ "${APPOFFLOAD_ALLOW_ANY_TARGET:-0}" = "1" ] && case "$1" in
                */"$MANAGED_DIR_NAME"/*/Application\ Support/.appoffload-staging-*) return 0 ;;
            esac
            return 1
            ;;
    esac
}

is_restore_staging_path() {
    [ "$(/usr/bin/dirname "$1")" = "$APP_SUPPORT_ROOT" ] || return 1
    case "$(/usr/bin/basename "$1")" in .*.appoffload-restore-*) return 0 ;; esac
    return 1
}

is_health_journal_path() {
    case "$1" in
        "$VOLUMES_ROOT"/*/"$MANAGED_DIR_NAME"/.transactions/*.state) return 0 ;;
        *)
            [ "${APPOFFLOAD_ALLOW_ANY_TARGET:-0}" = "1" ] && case "$1" in
                */"$MANAGED_DIR_NAME"/.transactions/*.state) return 0 ;;
            esac
            return 1
            ;;
    esac
}

clean_health_staging() {
    local stage="$1"
    APPOFFLOAD_ERROR=""
    { is_health_staging_path "$stage" || is_restore_staging_path "$stage"; } || { APPOFFLOAD_ERROR="Safety guard refused unexpected staging path: $stage"; return 1; }
    [ -e "$stage" ] || { APPOFFLOAD_ERROR="Staging path no longer exists."; return 1; }
    ensure_not_in_use "$stage" || return 1
    /bin/rm -rf "$stage"
}

recover_local_backup() {
    local backup="$1" base rest name source
    APPOFFLOAD_ERROR=""
    case "$backup" in "$APP_SUPPORT_ROOT"/.*.appoffload-backup-*) ;; *) APPOFFLOAD_ERROR="Safety guard refused unexpected backup path."; return 1 ;; esac
    [ -e "$backup" ] || { APPOFFLOAD_ERROR="Backup no longer exists."; return 1; }
    base=$(/usr/bin/basename "$backup"); rest=${base#.}; name=${rest%%.appoffload-backup-*}; source="$APP_SUPPORT_ROOT/$name"
    if [ -e "$source" ] || [ -L "$source" ]; then APPOFFLOAD_ERROR="Original path is occupied; backup was not changed."; return 1; fi
    /bin/mv "$backup" "$source" || { APPOFFLOAD_ERROR="Could not restore the local rollback copy."; return 1; }
}

recover_incomplete_transaction() {
    local journal="$1" phase encoded source backup stage stage_identity final old_destination operation current="" workdir
    APPOFFLOAD_ERROR=""
    is_health_journal_path "$journal" || { APPOFFLOAD_ERROR="Safety guard refused unexpected transaction record."; return 1; }
    [ -f "$journal" ] || { APPOFFLOAD_ERROR="Transaction record no longer exists."; return 1; }
    phase=$(/usr/bin/awk -F= '$1 == "phase" {print $2; exit}' "$journal")
    encoded=$(/usr/bin/awk -F= '$1 == "source" {print substr($0, index($0, "=")+1); exit}' "$journal"); source=$(decode_field "$encoded")
    encoded=$(/usr/bin/awk -F= '$1 == "backup" {print substr($0, index($0, "=")+1); exit}' "$journal"); backup=$(decode_field "$encoded")
    encoded=$(/usr/bin/awk -F= '$1 == "stage" {print substr($0, index($0, "=")+1); exit}' "$journal"); stage=$(decode_field "$encoded")
    stage_identity=$(/usr/bin/awk -F= '$1 == "stage_identity" {print $2; exit}' "$journal")
    encoded=$(/usr/bin/awk -F= '$1 == "final" {print substr($0, index($0, "=")+1); exit}' "$journal"); final=$(decode_field "$encoded")
    encoded=$(/usr/bin/awk -F= '$1 == "old_destination" {print substr($0, index($0, "=")+1); exit}' "$journal"); old_destination=$(decode_field "$encoded")
    operation=$(/usr/bin/awk -F= '$1 == "operation" {print $2; exit}' "$journal")
    if [ -z "$operation" ]; then
        case "$backup" in *appoffload-delete-*) operation=delete ;; *appoffload-backup-*) operation=offload ;; esac
        [ -n "$old_destination" ] && operation=move
    fi
    is_application_support_child "$source" || { APPOFFLOAD_ERROR="Transaction source failed its safety check."; return 1; }
    if [ -n "$backup" ]; then
        case "$backup" in "$APP_SUPPORT_ROOT"/.*.appoffload-backup-*|"$APP_SUPPORT_ROOT"/.*.appoffload-delete-*) ;; *) APPOFFLOAD_ERROR="Transaction rollback path failed its safety check."; return 1 ;; esac
    fi
    [ -z "$stage" ] || { is_health_staging_path "$stage" || is_restore_staging_path "$stage"; } || { APPOFFLOAD_ERROR="Transaction staging path failed its safety check."; return 1; }
    [ -z "$final" ] || is_managed_destination "$final" || { APPOFFLOAD_ERROR="Transaction destination failed its safety check."; return 1; }
    [ -z "$old_destination" ] || is_managed_destination "$old_destination" || { APPOFFLOAD_ERROR="Old destination failed its safety check."; return 1; }
    [ -L "$source" ] && current=$(absolute_link_destination "$source" 2>/dev/null || true)
    case "$operation" in
        move)
            if same_destination "$current" "$final" && [ -d "$final" ]; then
                if [ -d "$old_destination" ]; then
                    if [ "$phase" != "removing-old" ]; then
                        workdir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/appoffload-move-repair.XXXXXX") || return 1
                        verify_trees "$old_destination" "$final" "$workdir" || { /bin/rm -rf "$workdir"; return 1; }
                        /bin/rm -rf "$workdir"
                    fi
                    safe_remove_managed_destination "$old_destination" || return 1
                fi
                register_offload "$source" "$final" >/dev/null 2>&1 || true
            elif same_destination "$current" "$old_destination" && [ -d "$old_destination" ]; then
                [ ! -e "$final" ] || safe_remove_managed_destination "$final" || return 1
            else
                APPOFFLOAD_ERROR="Move needs manual review; the link does not point to either verified copy."
                return 1
            fi
            ;;
        restore)
            if [ -d "$source" ] && [ ! -L "$source" ]; then
                if [ -d "$final" ]; then
                    if [ "$phase" != "local-active" ] && [ "$phase" != "removing-external" ]; then
                        if [ "$phase" != "restoring" ] || [ -z "$stage_identity" ] || [ -e "$stage" ] || [ -L "$stage" ] ||
                           [ "$(directory_identity "$source" 2>/dev/null || true)" != "$stage_identity" ]; then
                            workdir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/appoffload-restore-repair.XXXXXX") || return 1
                            verify_trees "$final" "$source" "$workdir" || { /bin/rm -rf "$workdir"; return 1; }
                            /bin/rm -rf "$workdir"
                        fi
                    fi
                    safe_remove_managed_destination "$final" || return 1
                fi
                remove_offload_record "$source" >/dev/null 2>&1 || true
            elif same_destination "$current" "$final" && [ -d "$final" ]; then :
            elif [ ! -e "$source" ] && [ ! -L "$source" ] && [ -d "$final" ]; then
                /bin/ln -s "$final" "$source" || return 1
            else APPOFFLOAD_ERROR="Restore needs manual review; original data is unavailable."; return 1; fi
            ;;
        delete)
            if [ "$phase" = "removing-external" ]; then
                [ ! -e "$final" ] || safe_remove_managed_destination "$final" || return 1
                [ ! -L "$backup" ] || /bin/unlink "$backup" || return 1
                if [ -L "$source" ] && same_destination "$(absolute_link_destination "$source" 2>/dev/null || true)" "$final"; then
                    /bin/unlink "$source" || return 1
                fi
                remove_offload_record "$source" >/dev/null 2>&1 || true
            elif [ -d "$final" ]; then
                if [ ! -e "$source" ] && [ ! -L "$source" ]; then
                    if [ -L "$backup" ]; then /bin/mv -h "$backup" "$source" || return 1
                    else /bin/ln -s "$final" "$source" || return 1; fi
                fi
                same_destination "$(absolute_link_destination "$source" 2>/dev/null || true)" "$final" || { APPOFFLOAD_ERROR="Delete needs manual review; original path conflicts."; return 1; }
                [ ! -L "$backup" ] || /bin/unlink "$backup" || return 1
            else
                [ ! -L "$backup" ] || /bin/unlink "$backup" || return 1
                remove_offload_record "$source" >/dev/null 2>&1 || true
            fi
            ;;
        offload|"")
            if [ -n "$backup" ] && { [ -e "$backup" ] || [ -L "$backup" ]; }; then
                if [ ! -e "$source" ] && [ ! -L "$source" ]; then
                    /bin/mv "$backup" "$source" || { APPOFFLOAD_ERROR="Could not restore the transaction rollback copy."; return 1; }
                elif [ -L "$source" ] && same_destination "$(absolute_link_destination "$source" 2>/dev/null)" "$final" && [ -d "$final" ]; then
                    if [ "$phase" != "removing-local" ]; then
                        workdir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/appoffload-offload-repair.XXXXXX") || return 1
                        verify_trees "$backup" "$final" "$workdir" || { /bin/rm -rf "$workdir"; return 1; }
                        /bin/rm -rf "$workdir"
                    fi
                    case "$backup" in "$APP_SUPPORT_ROOT"/.*.appoffload-*) /bin/rm -rf "$backup" ;; esac
                else
                    APPOFFLOAD_ERROR="Transaction needs manual review because both source and rollback data exist."
                    return 1
                fi
            fi
            if [ -d "$source" ] && [ ! -L "$source" ] && [ -d "$final" ]; then
                workdir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/appoffload-orphan-repair.XXXXXX") || return 1
                verify_trees "$source" "$final" "$workdir" || { /bin/rm -rf "$workdir"; APPOFFLOAD_ERROR="The external copy differs from the local folder; review both copies manually."; return 1; }
                /bin/rm -rf "$workdir"
                safe_remove_managed_destination "$final" || return 1
            fi
            if [ -L "$source" ] && same_destination "$(absolute_link_destination "$source" 2>/dev/null || true)" "$final"; then
                register_offload "$source" "$final" >/dev/null 2>&1 || true
            fi
            ;;
        *) APPOFFLOAD_ERROR="Unknown transaction operation: $operation"; return 1 ;;
    esac
    if [ -n "$stage" ] && [ -e "$stage" ]; then clean_health_staging "$stage" || return 1; fi
    mark_journal_phase "$journal" recovered
}

processes_using() {
    local path="$1" current_pid="" current_command=""
    local lsof_bin="${APPOFFLOAD_LSOF:-/usr/sbin/lsof}"
    [ -x "$lsof_bin" ] || return 0
    "$lsof_bin" -Fpc +D "$path" 2>/dev/null | while IFS= read -r line; do
        case "$line" in
            p*) current_pid=${line#p} ;;
            c*)
                current_command=${line#c}
                [ "$current_pid" = "$$" ] || printf '%s\t%s\n' "$current_pid" "$current_command"
                ;;
        esac
    done
}

ensure_not_in_use() {
    local path="$1" users
    users=$(processes_using "$path")
    if [ -n "$users" ]; then
        APPOFFLOAD_ERROR="Files are currently open. Quit these processes first: $(printf '%s' "$users" | /usr/bin/awk -F '\t' '{printf "%s (PID %s) ", $2, $1}')"
        return 1
    fi
    return 0
}

sha256_file() {
    /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

create_manifest() {
    local root="$1" output="$2" temp item relative encoded kind size digest target
    temp="${output}.unsorted"
    : > "$temp" || return 1

    while IFS= read -r -d '' item; do
        relative=${item#"$root"/}
        encoded=$(encode_field "$relative") || return 1
        if [ -L "$item" ]; then
            kind="L"
            target=$(/usr/bin/readlink "$item") || return 1
            digest=$(encode_field "$target") || return 1
            printf '%s\t%s\t0\t%s\n' "$encoded" "$kind" "$digest" >> "$temp"
        elif [ -f "$item" ]; then
            kind="F"
            size=$(/usr/bin/stat -f '%z' "$item") || return 1
            digest=$(sha256_file "$item") || return 1
            printf '%s\t%s\t%s\t%s\n' "$encoded" "$kind" "$size" "$digest" >> "$temp"
        elif [ -d "$item" ]; then
            printf '%s\tD\t0\t-\n' "$encoded" >> "$temp"
        else
            APPOFFLOAD_ERROR="Unsupported special file: $item"
            return 1
        fi
    done < <(/usr/bin/find "$root" -mindepth 1 -print0)

    LC_ALL=C /usr/bin/sort "$temp" > "$output"
    /bin/rm -f "$temp"
}

verify_trees() {
    local source="$1" destination="$2" workdir="$3"
    local before="$workdir/source.manifest" after="$workdir/destination.manifest" final_source="$workdir/source-final.manifest"
    emit_progress "Checksumming source" 0 "Building SHA-256 manifest"
    create_manifest "$source" "$before" || return 1
    emit_progress "Checksumming source" 100 "Manifest complete"
    emit_progress "Verifying copy" 5 "Hashing copied data"
    create_manifest "$destination" "$after" || return 1
    if ! /usr/bin/cmp -s "$before" "$after"; then
        APPOFFLOAD_ERROR="SHA-256 manifests differ; the original data was left untouched."
        return 1
    fi
    # Hash the source again to detect writes that raced with the copy/first hash.
    create_manifest "$source" "$final_source" || return 1
    if ! /usr/bin/cmp -s "$after" "$final_source"; then
        APPOFFLOAD_ERROR="The source changed during verification; quit the app and retry."
        return 1
    fi
    emit_progress "Verifying copy" 100 "Every file matches"
}

copy_with_progress() {
    local source="$1" destination="$2" total="$3" pid copied percent status
    local ditto_bin="${APPOFFLOAD_DITTO:-/usr/bin/ditto}"
    "$ditto_bin" --rsrc --extattr --acl "$source" "$destination" &
    pid=$!
    ACTIVE_COPY_PID=$pid
    while /bin/kill -0 "$pid" 2>/dev/null; do
        copied=$(path_bytes "$destination" 2>/dev/null || echo 0)
        if [ "$total" -gt 0 ]; then
            percent=$((copied * 100 / total))
            [ "$percent" -gt 99 ] && percent=99
        else
            percent=0
        fi
        emit_progress "Copying" "$percent" "$(human_bytes "$copied") / $(human_bytes "$total")"
        /bin/sleep 0.25
    done
    wait "$pid"
    status=$?
    ACTIVE_COPY_PID=""
    [ "$status" -eq 0 ] || {
        APPOFFLOAD_ERROR="ditto could not copy the folder (exit $status)."
        return "$status"
    }
    emit_progress "Copying" 100 "$(human_bytes "$total") copied"
}

filesystem_personality() {
    /usr/sbin/diskutil info "$1" 2>/dev/null | /usr/bin/awk -F ': *' '/File System Personality/ {print $2; exit}'
}

ensure_compatible_filesystem() {
    local target="$1" personality
    [ "${APPOFFLOAD_ALLOW_ANY_TARGET:-0}" = "1" ] && return 0
    personality=$(filesystem_personality "$target")
    case "$personality" in
        *APFS*|*"Mac OS Extended"*) return 0 ;;
        "") APPOFFLOAD_ERROR="Could not identify the target filesystem." ;;
        *) APPOFFLOAD_ERROR="Unsupported target filesystem: $personality. Use APFS (recommended) or Mac OS Extended to preserve app metadata." ;;
    esac
    return 1
}

acquire_lock() {
    LOCK_DIR="$APP_SUPPORT_ROOT/.appoffload.lock"
    if /bin/mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" > "$LOCK_DIR/pid"
        return 0
    fi
    local old_pid=""
    [ -f "$LOCK_DIR/pid" ] && old_pid=$(/bin/cat "$LOCK_DIR/pid" 2>/dev/null)
    if [ -n "$old_pid" ] && /bin/kill -0 "$old_pid" 2>/dev/null; then
        APPOFFLOAD_ERROR="Another appoffload operation is running (PID $old_pid)."
        return 1
    fi
    /bin/rm -rf "$LOCK_DIR"
    /bin/mkdir "$LOCK_DIR" 2>/dev/null || { APPOFFLOAD_ERROR="Could not acquire the operation lock; another process may have taken it."; return 1; }
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
}

release_lock() {
    [ -n "$LOCK_DIR" ] && [ "$LOCK_DIR" != "/" ] && /bin/rm -rf "$LOCK_DIR"
    LOCK_DIR=""
}

write_journal() {
    local file="$1" phase="$2" temp="${1}.pending-$$"
    {
        printf 'version=1\nphase=%s\n' "$phase"
        printf 'source=%s\n' "$(encode_field "$ACTIVE_SOURCE")"
        printf 'backup=%s\n' "$(encode_field "$ACTIVE_BACKUP")"
        printf 'stage=%s\n' "$(encode_field "$ACTIVE_STAGE")"
        printf 'stage_identity=%s\n' "$ACTIVE_STAGE_ID"
        printf 'final=%s\n' "$(encode_field "$ACTIVE_FINAL")"
        printf 'old_destination=%s\n' "$(encode_field "$ACTIVE_OLD_DESTINATION")"
        printf 'operation=%s\n' "$ACTIVE_OPERATION"
    } > "$temp" || { /bin/rm -f "$temp"; return 1; }
    /bin/mv "$temp" "$file" || { /bin/rm -f "$temp"; return 1; }
}

mark_journal_phase() {
    local file="$1" phase="$2" temp
    [ -n "$file" ] && [ -f "$file" ] || return 0
    temp="${file}.phase-$$"
    /usr/bin/awk -F= -v phase="$phase" 'BEGIN {OFS="="} $1 == "phase" {$2=phase} {print}' "$file" > "$temp" && /bin/mv "$temp" "$file"
}

clear_active_transaction() {
    ACTIVE_PHASE=""
    ACTIVE_SOURCE=""
    ACTIVE_BACKUP=""
    ACTIVE_STAGE=""
    ACTIVE_STAGE_ID=""
    ACTIVE_FINAL=""
    ACTIVE_WORKDIR=""
    ACTIVE_COPY_PID=""
    ACTIVE_LINK_ROLLBACK=""
    ACTIVE_JOURNAL=""
    ACTIVE_OLD_DESTINATION=""
    ACTIVE_OPERATION=""
}

rollback_active_transaction() {
    local clean=1 current=""
    if [ -n "$ACTIVE_COPY_PID" ] && /bin/kill -0 "$ACTIVE_COPY_PID" 2>/dev/null; then
        /bin/kill -TERM "$ACTIVE_COPY_PID" 2>/dev/null || true
        wait "$ACTIVE_COPY_PID" 2>/dev/null || true
        ACTIVE_COPY_PID=""
    fi
    case "$ACTIVE_OPERATION:$ACTIVE_PHASE" in
    delete:removing-external|offload:removing-local) ;;
    *)
        if [ -n "$ACTIVE_BACKUP" ] && { [ -e "$ACTIVE_BACKUP" ] || [ -L "$ACTIVE_BACKUP" ]; }; then
            if [ -L "$ACTIVE_SOURCE" ]; then
                /bin/unlink "$ACTIVE_SOURCE" 2>/dev/null || true
            fi
            if [ ! -e "$ACTIVE_SOURCE" ] && [ ! -L "$ACTIVE_SOURCE" ]; then
                /bin/mv "$ACTIVE_BACKUP" "$ACTIVE_SOURCE" 2>/dev/null || true
            fi
        fi
        if [ -n "$ACTIVE_LINK_ROLLBACK" ] && [ ! -e "$ACTIVE_SOURCE" ] && [ ! -L "$ACTIVE_SOURCE" ]; then
            /bin/ln -s "$ACTIVE_LINK_ROLLBACK" "$ACTIVE_SOURCE" 2>/dev/null || true
        fi
        ;;
    esac
    if type rollback_migration_commits >/dev/null 2>&1; then
        rollback_migration_commits
    fi
    if [ -n "$ACTIVE_STAGE" ] && [ -e "$ACTIVE_STAGE" ]; then
        case "$ACTIVE_STAGE" in
            */.appoffload-staging-*|"$APP_SUPPORT_ROOT"/.*.appoffload-restore-*) /bin/rm -rf "$ACTIVE_STAGE" || clean=0 ;;
        esac
    fi
    if [ -n "$ACTIVE_JOURNAL" ]; then
        [ -L "$ACTIVE_SOURCE" ] && current=$(absolute_link_destination "$ACTIVE_SOURCE" 2>/dev/null || true)
        case "$ACTIVE_OPERATION" in
            offload)
                case "$ACTIVE_PHASE" in
                    copying|verified|source-moved|linked)
                        if [ -d "$ACTIVE_SOURCE" ] && [ ! -L "$ACTIVE_SOURCE" ] && [ -d "$ACTIVE_FINAL" ]; then
                            safe_remove_managed_destination "$ACTIVE_FINAL" || clean=0
                        fi
                        [ -d "$ACTIVE_SOURCE" ] && [ ! -L "$ACTIVE_SOURCE" ] || clean=0
                        ;;
                    *) clean=0 ;;
                esac
                ;;
            move)
                if same_destination "$current" "$ACTIVE_OLD_DESTINATION" && [ -d "$ACTIVE_FINAL" ]; then
                    safe_remove_managed_destination "$ACTIVE_FINAL" || clean=0
                fi
                same_destination "$current" "$ACTIVE_OLD_DESTINATION" || clean=0
                ;;
            restore) same_destination "$current" "$ACTIVE_FINAL" || clean=0 ;;
            delete)
                if [ "$ACTIVE_PHASE" = "removing-external" ]; then clean=0
                else same_destination "$current" "$ACTIVE_FINAL" && [ -d "$ACTIVE_FINAL" ] || clean=0; fi
                ;;
        esac
        if [ -n "$ACTIVE_BACKUP" ] && { [ -e "$ACTIVE_BACKUP" ] || [ -L "$ACTIVE_BACKUP" ]; }; then clean=0; fi
        if [ -n "$ACTIVE_STAGE" ] && [ -e "$ACTIVE_STAGE" ]; then clean=0; fi
        [ "$clean" -eq 1 ] && mark_journal_phase "$ACTIVE_JOURNAL" aborted
    fi
    if [ -n "$ACTIVE_WORKDIR" ] && [ -d "$ACTIVE_WORKDIR" ]; then
        case "$ACTIVE_WORKDIR" in
            "${TMPDIR:-/tmp}"/appoffload-*) /bin/rm -rf "$ACTIVE_WORKDIR" ;;
        esac
    fi
    if type rollback_migration_mount >/dev/null 2>&1; then
        rollback_migration_mount
    fi
    release_lock
    clear_active_transaction
}

offload_folder() {
    local source="$1" target="$2" name user_name managed_root transaction_root transaction_id
    local final stage backup workdir journal total free required copy_verified=0
    APPOFFLOAD_ERROR=""
    LAST_LOCAL_DELTA_BYTES=0
    LAST_EXTERNAL_BYTES=0
    [ -d "$source" ] && [ ! -L "$source" ] || {
        APPOFFLOAD_ERROR="Select a local Application Support folder, not a link: $source"
        return 1
    }
    is_application_support_child "$source" || {
        APPOFFLOAD_ERROR="Source must be an immediate child of $APP_SUPPORT_ROOT"
        return 1
    }
    [ -d "$target" ] && [ -w "$target" ] || {
        APPOFFLOAD_ERROR="Target is not a mounted writable directory: $target"
        return 1
    }
    if [ "${APPOFFLOAD_ALLOW_ANY_TARGET:-0}" != "1" ]; then
        case "$target" in "$VOLUMES_ROOT"/*) ;; *)
            APPOFFLOAD_ERROR="Target must be a mounted volume below $VOLUMES_ROOT"
            return 1
        esac
    fi
    ensure_compatible_filesystem "$target" || return 1
    ensure_not_in_use "$source" || return 1
    acquire_lock || return 1

    name=$(/usr/bin/basename "$source")
    user_name=${USER:-$(/usr/bin/id -un)}
    managed_root="$target/$MANAGED_DIR_NAME/$user_name/Application Support"
    transaction_root="$target/$MANAGED_DIR_NAME/.transactions"
    transaction_id=$(new_transaction_id)
    final="$managed_root/$name"
    stage="$managed_root/.appoffload-staging-$transaction_id-$name"
    backup="$APP_SUPPORT_ROOT/.$name.appoffload-backup-$transaction_id"
    workdir="${TMPDIR:-/tmp}/appoffload-$transaction_id"
    journal="$transaction_root/$transaction_id.state"

    if [ -e "$final" ] || [ -L "$final" ]; then
        APPOFFLOAD_ERROR="Destination already exists: $final"
        release_lock
        return 1
    fi
    total=$(path_bytes "$source") || { APPOFFLOAD_ERROR="Could not measure $source"; release_lock; return 1; }
    free=$(available_bytes "$target")
    required=$((total + total / 20 + 67108864))
    if [ -z "$free" ] || [ "$free" -lt "$required" ]; then
        APPOFFLOAD_ERROR="Not enough free space: need $(human_bytes "$required"), have $(human_bytes "${free:-0}")."
        release_lock
        return 1
    fi

    /bin/mkdir -p "$managed_root" "$transaction_root" "$workdir" || {
        APPOFFLOAD_ERROR="Could not create transaction directories on the target."
        release_lock
        return 1
    }
    ACTIVE_SOURCE="$source" ACTIVE_BACKUP="$backup" ACTIVE_STAGE="$stage" ACTIVE_FINAL="$final" ACTIVE_WORKDIR="$workdir" ACTIVE_JOURNAL="$journal" ACTIVE_OPERATION="offload"
    ACTIVE_PHASE="copying"
    write_journal "$journal" "$ACTIVE_PHASE" || { APPOFFLOAD_ERROR="Could not create the offload journal."; rollback_active_transaction; return 1; }
    emit_progress "Preflight" 100 "Apps closed; space available"

    if ! copy_with_progress "$source" "$stage" "$total"; then
        rollback_active_transaction
        return 1
    fi
    if ! verify_trees "$source" "$stage" "$workdir"; then
        rollback_active_transaction
        return 1
    fi
    ensure_not_in_use "$source" || { rollback_active_transaction; return 1; }
    copy_verified=1
    ACTIVE_PHASE="verified"
    write_journal "$journal" "$ACTIVE_PHASE" || { APPOFFLOAD_ERROR="Could not update the offload journal."; rollback_active_transaction; return 1; }

    emit_progress "Switching to symlink" 20 "Committing verified copy"
    /bin/mv "$stage" "$final" || { APPOFFLOAD_ERROR="Could not commit the external copy."; rollback_active_transaction; return 1; }
    ACTIVE_STAGE=""
    /bin/mv "$source" "$backup" || { APPOFFLOAD_ERROR="Could not create the local rollback copy."; rollback_active_transaction; return 1; }
    ACTIVE_PHASE="source-moved"
    write_journal "$journal" "$ACTIVE_PHASE" || { APPOFFLOAD_ERROR="Could not update the offload journal."; rollback_active_transaction; return 1; }
    if ! /bin/ln -s "$final" "$source"; then
        APPOFFLOAD_ERROR="Could not create the symbolic link; the local folder was restored."
        rollback_active_transaction
        return 1
    fi
    [ "$(/usr/bin/readlink "$source")" = "$final" ] || {
        APPOFFLOAD_ERROR="Symbolic-link validation failed; the local folder was restored."
        rollback_active_transaction
        return 1
    }
    emit_progress "Switching to symlink" 100 "Link is active"
    ACTIVE_PHASE="linked"
    write_journal "$journal" "$ACTIVE_PHASE" || { APPOFFLOAD_ERROR="Could not update the offload journal."; rollback_active_transaction; return 1; }

    emit_progress "Cleaning local copy" 30 "Removing verified rollback copy"
    ACTIVE_PHASE="removing-local"
    write_journal "$journal" "$ACTIVE_PHASE" || { APPOFFLOAD_ERROR="Could not update the offload journal."; rollback_active_transaction; return 1; }
    case "$backup" in
        "$APP_SUPPORT_ROOT"/.*.appoffload-backup-*)
            /bin/rm -rf "$backup" || { APPOFFLOAD_ERROR="The link is active, but the local rollback copy could not be removed: $backup"; release_lock; clear_active_transaction; return 1; }
            ;;
        *) APPOFFLOAD_ERROR="Safety guard refused to remove unexpected backup path: $backup"; release_lock; return 1 ;;
    esac
    emit_progress "Cleaning local copy" 100 "Local space reclaimed"
    ACTIVE_BACKUP=""
    ACTIVE_PHASE="complete"
    write_journal "$journal" "$ACTIVE_PHASE" || { APPOFFLOAD_ERROR="Offload is active, but the journal could not be completed."; release_lock; clear_active_transaction; return 1; }
    register_offload "$source" "$(cd "$final" && pwd -P)" "$(cd "$target" && pwd -P)" >/dev/null 2>&1 || true
    /bin/rm -rf "$workdir"
    release_lock
    clear_active_transaction
    LAST_LOCAL_DELTA_BYTES=$total
    LAST_EXTERNAL_BYTES=$total
    [ "$copy_verified" -eq 1 ]
}

restore_folder() {
    local source="$1" destination name transaction_id staging workdir journal total free required
    APPOFFLOAD_ERROR=""
    LAST_LOCAL_DELTA_BYTES=0
    LAST_EXTERNAL_BYTES=0
    is_application_support_child "$source" || {
        APPOFFLOAD_ERROR="Source must be an immediate child of $APP_SUPPORT_ROOT"
        return 1
    }
    destination=$(managed_link_destination "$source" 2>/dev/null) || {
        APPOFFLOAD_ERROR="This is not a link managed by appoffload: $source"
        return 1
    }
    [ -d "$destination" ] || { APPOFFLOAD_ERROR="External data is unavailable: $destination"; return 1; }
    ensure_not_in_use "$destination" || return 1
    acquire_lock || return 1
    name=$(/usr/bin/basename "$source")
    transaction_id=$(new_transaction_id)
    staging="$APP_SUPPORT_ROOT/.$name.appoffload-restore-$transaction_id"
    workdir="${TMPDIR:-/tmp}/appoffload-restore-$transaction_id"
    total=$(path_bytes "$destination") || { APPOFFLOAD_ERROR="Could not measure external data."; release_lock; return 1; }
    free=$(available_bytes "$APP_SUPPORT_ROOT")
    required=$((total + total / 20 + 67108864))
    if [ -z "$free" ] || [ "$free" -lt "$required" ]; then
        APPOFFLOAD_ERROR="Not enough local space: need $(human_bytes "$required"), have $(human_bytes "${free:-0}")."
        release_lock
        return 1
    fi
    /bin/mkdir -p "$workdir" || { APPOFFLOAD_ERROR="Could not create restore workspace."; release_lock; return 1; }
    journal="$destination"
    journal="${journal%/*/Application Support/*}/.transactions/$transaction_id.state"
    /bin/mkdir -p "${journal%/*}" || { APPOFFLOAD_ERROR="Could not create restore transaction record directory."; /bin/rm -rf "$workdir"; release_lock; return 1; }
    ACTIVE_SOURCE="$source" ACTIVE_STAGE="$staging" ACTIVE_FINAL="$destination" ACTIVE_WORKDIR="$workdir" ACTIVE_LINK_ROLLBACK="$destination" ACTIVE_JOURNAL="$journal" ACTIVE_OPERATION="restore" ACTIVE_PHASE="restoring"
    write_journal "$journal" "$ACTIVE_PHASE" || { APPOFFLOAD_ERROR="Could not create the restore journal."; rollback_active_transaction; return 1; }

    copy_with_progress "$destination" "$staging" "$total" || { rollback_active_transaction; return 1; }
    verify_trees "$destination" "$staging" "$workdir" || { rollback_active_transaction; return 1; }
    ACTIVE_STAGE_ID=$(directory_identity "$staging") || { APPOFFLOAD_ERROR="Could not identify the verified restore copy."; rollback_active_transaction; return 1; }
    write_journal "$journal" "$ACTIVE_PHASE" || { APPOFFLOAD_ERROR="Could not record the verified restore copy."; rollback_active_transaction; return 1; }
    emit_progress "Switching to local" 30 "Replacing managed link"
    /bin/unlink "$source" || { APPOFFLOAD_ERROR="Could not remove the managed link."; rollback_active_transaction; return 1; }
    if ! /bin/mv "$staging" "$source"; then
        APPOFFLOAD_ERROR="Could not activate the restored folder; the external link was recreated."
        rollback_active_transaction
        return 1
    fi
    ACTIVE_STAGE=""
    ACTIVE_PHASE="local-active"
    write_journal "$journal" "$ACTIVE_PHASE" || { APPOFFLOAD_ERROR="Local restore is active, but the journal could not be updated."; release_lock; clear_active_transaction; return 1; }
    emit_progress "Switching to local" 100 "Local folder is active"
    ACTIVE_PHASE="removing-external"
    write_journal "$journal" "$ACTIVE_PHASE" || { APPOFFLOAD_ERROR="Local restore is active, but the cleanup journal could not be updated."; release_lock; clear_active_transaction; return 1; }
    if ! safe_remove_managed_destination "$destination"; then
        APPOFFLOAD_ERROR="Restore activated the local folder, but the external copy could not be removed: $destination"
        release_lock
        clear_active_transaction
        return 1
    fi
    remove_offload_record "$source" >/dev/null 2>&1 || true
    ACTIVE_PHASE="complete"
    write_journal "$journal" "$ACTIVE_PHASE" || { APPOFFLOAD_ERROR="Restore succeeded, but the journal could not be completed."; release_lock; clear_active_transaction; return 1; }
    /bin/rm -rf "$workdir"
    release_lock
    clear_active_transaction
    LAST_LOCAL_DELTA_BYTES=$((0 - total))
    LAST_EXTERNAL_BYTES=$total
    emit_progress "Complete" 100 "External copy removed"
}

safe_remove_managed_destination() {
    local destination="$1"
    is_managed_destination "$destination" || {
        APPOFFLOAD_ERROR="Safety guard refused unexpected managed-data path: $destination"
        return 1
    }
    /bin/rm -rf "$destination" || { APPOFFLOAD_ERROR="Could not remove managed data: $destination"; return 1; }
}

move_offload() {
    local source="$1" target="$2" old_destination name user_name managed_root transaction_root transaction_id
    local final stage temporary_link workdir journal total free required
    APPOFFLOAD_ERROR=""
    LAST_LOCAL_DELTA_BYTES=0
    LAST_EXTERNAL_BYTES=0
    is_application_support_child "$source" || {
        APPOFFLOAD_ERROR="Source must be an immediate child of $APP_SUPPORT_ROOT"
        return 1
    }
    old_destination=$(managed_link_destination "$source" 2>/dev/null) || {
        APPOFFLOAD_ERROR="This is not a link managed by appoffload: $source"
        return 1
    }
    [ -d "$old_destination" ] || { APPOFFLOAD_ERROR="Current external data is unavailable: $old_destination"; return 1; }
    [ -d "$target" ] && [ -w "$target" ] || { APPOFFLOAD_ERROR="Target is not a mounted writable directory: $target"; return 1; }
    if [ "${APPOFFLOAD_ALLOW_ANY_TARGET:-0}" != "1" ]; then
        case "$target" in "$VOLUMES_ROOT"/*) ;; *) APPOFFLOAD_ERROR="Target must be a mounted volume below $VOLUMES_ROOT"; return 1 ;; esac
    fi
    ensure_compatible_filesystem "$target" || return 1
    ensure_not_in_use "$old_destination" || return 1
    acquire_lock || return 1

    name=$(/usr/bin/basename "$source")
    user_name=${USER:-$(/usr/bin/id -un)}
    managed_root="$target/$MANAGED_DIR_NAME/$user_name/Application Support"
    transaction_root="$target/$MANAGED_DIR_NAME/.transactions"
    transaction_id=$(new_transaction_id)
    final="$managed_root/$name"
    stage="$managed_root/.appoffload-staging-$transaction_id-$name"
    temporary_link="$APP_SUPPORT_ROOT/.$name.appoffload-link-$transaction_id"
    workdir="${TMPDIR:-/tmp}/appoffload-move-$transaction_id"
    journal="$transaction_root/$transaction_id.state"
    if [ "$final" = "$old_destination" ]; then
        APPOFFLOAD_ERROR="The offload is already stored on that target disk."
        release_lock
        return 1
    fi
    if [ -e "$final" ] || [ -L "$final" ]; then
        APPOFFLOAD_ERROR="Destination already exists: $final"
        release_lock
        return 1
    fi
    total=$(path_bytes "$old_destination") || { APPOFFLOAD_ERROR="Could not measure external data."; release_lock; return 1; }
    free=$(available_bytes "$target")
    required=$((total + total / 20 + 67108864))
    if [ -z "$free" ] || [ "$free" -lt "$required" ]; then
        APPOFFLOAD_ERROR="Not enough target space: need $(human_bytes "$required"), have $(human_bytes "${free:-0}")."
        release_lock
        return 1
    fi
    /bin/mkdir -p "$managed_root" "$transaction_root" "$workdir" || {
        APPOFFLOAD_ERROR="Could not create transaction directories on the new target."
        release_lock
        return 1
    }
    ACTIVE_SOURCE="$source" ACTIVE_STAGE="$stage" ACTIVE_FINAL="$final" ACTIVE_WORKDIR="$workdir" ACTIVE_LINK_ROLLBACK="$old_destination" ACTIVE_OLD_DESTINATION="$old_destination" ACTIVE_JOURNAL="$journal" ACTIVE_OPERATION="move" ACTIVE_PHASE="moving"
    write_journal "$journal" "$ACTIVE_PHASE" || { APPOFFLOAD_ERROR="Could not create the move journal."; rollback_active_transaction; return 1; }
    emit_progress "Preflight" 100 "Source idle; target space available"
    copy_with_progress "$old_destination" "$stage" "$total" || { rollback_active_transaction; return 1; }
    verify_trees "$old_destination" "$stage" "$workdir" || { rollback_active_transaction; return 1; }
    ensure_not_in_use "$old_destination" || { rollback_active_transaction; return 1; }
    /bin/mv "$stage" "$final" || { APPOFFLOAD_ERROR="Could not commit the new external copy."; rollback_active_transaction; return 1; }
    ACTIVE_STAGE=""
    emit_progress "Switching offload" 40 "Retargeting managed link"
    /bin/ln -s "$final" "$temporary_link" || { APPOFFLOAD_ERROR="Could not prepare the replacement link."; rollback_active_transaction; return 1; }
    if ! /bin/mv -h "$temporary_link" "$source"; then
        /bin/unlink "$temporary_link" 2>/dev/null || true
        APPOFFLOAD_ERROR="Could not activate the replacement link; the old offload remains active."
        rollback_active_transaction
        return 1
    fi
    [ "$(/usr/bin/readlink "$source")" = "$final" ] || {
        APPOFFLOAD_ERROR="Replacement-link validation failed; both external copies were retained."
        release_lock
        clear_active_transaction
        return 1
    }
    emit_progress "Switching offload" 100 "New external copy is active"
    ACTIVE_LINK_ROLLBACK=""
    ACTIVE_PHASE="new-link-active"
    write_journal "$journal" "$ACTIVE_PHASE" || { APPOFFLOAD_ERROR="New offload is active, but the journal could not be updated."; release_lock; clear_active_transaction; return 1; }
    ACTIVE_PHASE="removing-old"
    write_journal "$journal" "$ACTIVE_PHASE" || { APPOFFLOAD_ERROR="New offload is active, but the cleanup journal could not be updated."; release_lock; clear_active_transaction; return 1; }
    if ! safe_remove_managed_destination "$old_destination"; then
        release_lock
        clear_active_transaction
        return 1
    fi
    register_offload "$source" "$(cd "$final" && pwd -P)" "$(cd "$target" && pwd -P)" >/dev/null 2>&1 || true
    /bin/rm -rf "$workdir"
    ACTIVE_PHASE="complete"
    write_journal "$journal" "$ACTIVE_PHASE" || { APPOFFLOAD_ERROR="Move succeeded, but the journal could not be completed."; release_lock; clear_active_transaction; return 1; }
    release_lock
    clear_active_transaction
    LAST_EXTERNAL_BYTES=$total
    emit_progress "Complete" 100 "Old external copy removed"
}

delete_offload() {
    local source="$1" destination name transaction_id link_backup total journal
    APPOFFLOAD_ERROR=""
    LAST_LOCAL_DELTA_BYTES=0
    LAST_EXTERNAL_BYTES=0
    is_application_support_child "$source" || {
        APPOFFLOAD_ERROR="Source must be an immediate child of $APP_SUPPORT_ROOT"
        return 1
    }
    destination=$(managed_link_destination "$source" 2>/dev/null) || {
        APPOFFLOAD_ERROR="This is not a link managed by appoffload: $source"
        return 1
    }
    [ -d "$destination" ] || { APPOFFLOAD_ERROR="External data is unavailable: $destination"; return 1; }
    ensure_not_in_use "$destination" || return 1
    acquire_lock || return 1
    name=$(/usr/bin/basename "$source")
    transaction_id=$(new_transaction_id)
    link_backup="$APP_SUPPORT_ROOT/.$name.appoffload-delete-$transaction_id"
    total=$(path_bytes "$destination") || { APPOFFLOAD_ERROR="Could not measure external data."; release_lock; return 1; }
    journal="${destination%/*/Application Support/*}/.transactions/$transaction_id.state"
    /bin/mkdir -p "${journal%/*}" || { APPOFFLOAD_ERROR="Could not create delete transaction record directory."; release_lock; return 1; }
    ACTIVE_SOURCE="$source" ACTIVE_BACKUP="$link_backup" ACTIVE_FINAL="$destination" ACTIVE_LINK_ROLLBACK="$destination" ACTIVE_JOURNAL="$journal" ACTIVE_OPERATION="delete" ACTIVE_PHASE="deleting"
    write_journal "$journal" "$ACTIVE_PHASE" || { APPOFFLOAD_ERROR="Could not create the delete journal."; rollback_active_transaction; return 1; }
    if ! /bin/mv -h "$source" "$link_backup"; then
        APPOFFLOAD_ERROR="Could not deactivate the managed link."
        rollback_active_transaction
        return 1
    fi
    emit_progress "Deleting offload" 35 "Managed link deactivated"
    ACTIVE_PHASE="removing-external"
    write_journal "$journal" "$ACTIVE_PHASE" || { APPOFFLOAD_ERROR="Could not update the delete journal."; rollback_active_transaction; return 1; }
    if ! safe_remove_managed_destination "$destination"; then
        rollback_active_transaction
        return 1
    fi
    if [ -L "$link_backup" ]; then
        /bin/unlink "$link_backup" || { APPOFFLOAD_ERROR="The external data was removed, but its hidden link could not be removed: $link_backup"; release_lock; clear_active_transaction; return 1; }
    fi
    remove_offload_record "$source" >/dev/null 2>&1 || true
    ACTIVE_BACKUP="" ACTIVE_LINK_ROLLBACK=""
    ACTIVE_PHASE="complete"
    write_journal "$journal" "$ACTIVE_PHASE" || { APPOFFLOAD_ERROR="Offload was deleted, but the journal could not be completed."; release_lock; clear_active_transaction; return 1; }
    release_lock
    clear_active_transaction
    LAST_EXTERNAL_BYTES=$total
    emit_progress "Deleting offload" 100 "External data permanently removed"
}
