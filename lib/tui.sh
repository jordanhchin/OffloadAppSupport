#!/bin/bash

# ANSI terminal interface. No dialog, fzf, gum, or Python dependency required.

C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_DIM=$'\033[2m'
C_CYAN=$'\033[38;5;44m'
C_BLUE=$'\033[38;5;75m'
C_GREEN=$'\033[38;5;78m'
C_YELLOW=$'\033[38;5;221m'
C_RED=$'\033[38;5;203m'
C_PANEL=$'\033[48;5;236m'
CURSOR=0
SCROLL=0
SESSION_DELTA=0
SESSION_ACTIONS=()
MENU_LABELS=()
MENU_VALUES=()
DISK_STATUS_ITEMS=()
DISK_STATUS_CACHE_TIME=0

tui_cleanup() {
    printf '%s\033[?25h\033[?1049l' "$C_RESET"
}

tui_enter() {
    printf '\033[?1049h\033[?25l'
    trap 'rollback_active_transaction; tui_cleanup; exit 130' INT TERM
}

terminal_width() {
    local width size
    size=$(/bin/stty size 2>/dev/null || true)
    width=${size##* }
    case "$width" in ''|*[!0-9]*) width=$(tput cols 2>/dev/null || echo 80) ;; esac
    [ "$width" -lt 20 ] && width=20
    echo "$width"
}

terminal_height() {
    local height size
    size=$(/bin/stty size 2>/dev/null || true)
    height=${size%% *}
    case "$height" in ''|*[!0-9]*) height=$(tput lines 2>/dev/null || echo 24) ;; esac
    [ "$height" -lt 8 ] && height=8
    echo "$height"
}

refresh_disk_status() {
    local now path label stats device total used percent seen_devices="" token
    now=$(/bin/date +%s)
    if [ "${#DISK_STATUS_ITEMS[@]}" -gt 0 ] && [ $((now - DISK_STATUS_CACHE_TIME)) -lt 2 ]; then return; fi
    DISK_STATUS_ITEMS=()
    for path in "$APP_SUPPORT_ROOT" "$VOLUMES_ROOT"/*; do
        [ -d "$path" ] || continue
        stats=$(/bin/df -Pk "$path" 2>/dev/null | /usr/bin/awk 'NR == 2 {
            percent = ($2 > 0) ? ($3 * 100 / $2) : 0
            printf "%s\t%.0f\t%.0f\t%.0f%%\n", $1, $2 * 1024, $3 * 1024, percent
        }')
        [ -n "$stats" ] || continue
        IFS=$'\t' read -r device total used percent <<< "$stats"
        case "$seen_devices" in *"|$device|"*) continue ;; esac
        seen_devices="$seen_devices|$device|"
        if [ "$path" = "$APP_SUPPORT_ROOT" ]; then label="Local"; else label=$(/usr/bin/basename "$path"); fi
        label=$(truncate_text "$label" 16)
        token="$label $(human_bytes "$total") cap · $(human_bytes "$used") used · $percent"
        DISK_STATUS_ITEMS+=("$token")
    done
    DISK_STATUS_CACHE_TIME=$now
}

status_bar_rows() {
    local width height total=7 item needed maximum
    width=$(terminal_width); height=$(terminal_height)
    if [ "$width" -lt 55 ] || [ "$height" -lt 12 ]; then echo 0; return; fi
    [ "${#DISK_STATUS_ITEMS[@]}" -gt 0 ] || { echo 0; return; }
    for item in "${DISK_STATUS_ITEMS[@]}"; do total=$((total + ${#item} + 3)); done
    needed=$(((total + width - 3) / (width - 2)))
    maximum=$((height / 10))
    [ "$maximum" -lt 1 ] && maximum=1
    [ "$maximum" -gt 4 ] && maximum=4
    [ "$needed" -gt "$maximum" ] && needed=$maximum
    echo "$needed"
}

draw_disk_status_bar() {
    local width height rows max_width prefix current candidate item displayed=0 hidden i start suffix allowed
    local lines=()
    refresh_disk_status
    width=$(terminal_width); height=$(terminal_height); rows=$(status_bar_rows)
    [ "$rows" -gt 0 ] || return
    max_width=$((width - 2))
    prefix="Disks: "
    current="$prefix"
    for item in "${DISK_STATUS_ITEMS[@]}"; do
        if [ "$current" = "$prefix" ] || [ "$current" = "       " ]; then candidate="$current$item"; else candidate="$current  •  $item"; fi
        if [ "${#candidate}" -le "$max_width" ]; then
            current="$candidate"; displayed=$((displayed + 1))
        elif [ "${#lines[@]}" -lt $((rows - 1)) ]; then
            lines+=("$current")
            current="       $item"
            displayed=$((displayed + 1))
        else
            break
        fi
    done
    hidden=$((${#DISK_STATUS_ITEMS[@]} - displayed))
    if [ "$hidden" -gt 0 ]; then
        suffix="  •  +$hidden more"
        allowed=$((max_width - ${#suffix}))
        current="$(truncate_text "$current" "$allowed")$suffix"
    fi
    lines+=("$current")
    while [ "${#lines[@]}" -lt "$rows" ]; do lines+=(""); done
    start=$((height - rows + 1))
    for ((i=0; i<rows; i++)); do
        printf '\033[%s;1H\033[2K%s%-*s%s' "$((start + i))" "$C_PANEL$C_BOLD" "$width" " ${lines[$i]}" "$C_RESET"
    done
    # Terminal.app does not consistently restore CSI s/u cursor state. Every
    # caller draws the bar immediately after the three-row header, so return to
    # that content origin explicitly.
    printf '\033[4;1H'
}

truncate_text() {
    local text="$1" max="$2"
    if [ "${#text}" -le "$max" ]; then printf '%s' "$text"; else printf '%s…' "${text:0:$((max - 1))}"; fi
}

draw_header() {
    local subtitle="$1" width
    width=$(terminal_width)
    printf '\033[2J\033[H'
    printf '%s%s  APPSUPPORT OFFLOAD  %s%s\n' "$C_PANEL" "$C_BOLD" "$C_RESET" "$C_CYAN"
    printf '%s%s%s\n' "$C_BOLD" "$(truncate_text "$subtitle" "$width")" "$C_RESET"
    printf '%s' "$C_DIM"
    printf '%*s\n' "$width" '' | tr ' ' '─'
    printf '%s' "$C_RESET"
    draw_disk_status_bar
}

read_key() {
    local key rest
    IFS= read -rsn1 key
    if [ "$key" = $'\033' ]; then
        # A single Esc must return as a key, while arrow-key bytes arrive next.
        # Bash 3.2 supports whole-second timeouts only.
        if IFS= read -rsn1 -t 1 rest; then
            key="$key$rest"
            if [ "$rest" = "[" ] || [ "$rest" = "O" ]; then
                rest=""
                IFS= read -rsn1 -t 1 rest || true
                key="$key$rest"
            fi
        fi
    fi
    printf '%s' "$key"
}

menu_select() {
    local title="$1" footer="$2" count=${#MENU_LABELS[@]} key i start end visible width height status_rows label
    CURSOR=0 SCROLL=0
    [ "$count" -gt 0 ] || return 1
    while true; do
        draw_header "$title"
        width=$(terminal_width)
        height=$(terminal_height)
        status_rows=$(status_bar_rows)
        visible=$((height - status_rows - 6))
        [ "$visible" -lt 3 ] && visible=3
        [ "$CURSOR" -lt "$SCROLL" ] && SCROLL=$CURSOR
        [ "$CURSOR" -ge $((SCROLL + visible)) ] && SCROLL=$((CURSOR - visible + 1))
        start=$SCROLL
        end=$((start + visible))
        [ "$end" -gt "$count" ] && end=$count
        for ((i=start; i<end; i++)); do
            label=${MENU_LABELS[$i]}
            if [ "$i" -eq "$CURSOR" ]; then
                printf '%s%s  › %-*s%s\n' "$C_BLUE" "$C_BOLD" "$((width - 5))" "$(truncate_text "$label" "$((width - 7))")" "$C_RESET"
            else
                printf '    %-*s\n' "$((width - 5))" "$(truncate_text "$label" "$((width - 7))")"
            fi
        done
        for ((i=end; i<start+visible; i++)); do printf '\n'; done
        printf '\n%s%s%s\n' "$C_DIM" "$footer" "$C_RESET"
        key=$(read_key)
        case "$key" in
            $'\033[A'|k) [ "$CURSOR" -gt 0 ] && CURSOR=$((CURSOR - 1)) ;;
            $'\033[B'|j) [ "$CURSOR" -lt $((count - 1)) ] && CURSOR=$((CURSOR + 1)) ;;
            '') SELECTED_VALUE=${MENU_VALUES[$CURSOR]}; SELECTED_LABEL=${MENU_LABELS[$CURSOR]}; return 0 ;;
            q|$'\033') return 1 ;;
        esac
    done
}

confirm_action() {
    local title="$1" line1="$2" line2="$3" key
    while true; do
        draw_header "$title"
        printf '\n  %s%s%s\n' "$C_BOLD" "$line1" "$C_RESET"
        printf '  %s%s%s\n\n' "$C_DIM" "$line2" "$C_RESET"
        printf '  %s[y]%s Continue    %s[n]%s Cancel\n' "$C_GREEN" "$C_RESET" "$C_YELLOW" "$C_RESET"
        key=$(read_key)
        case "$key" in y|Y) return 0 ;; n|N|q|$'\033') return 1 ;; esac
    done
}

ui_progress() {
    local phase="$1" percent="$2" detail="$3" width=42 filled empty bar
    filled=$((percent * width / 100))
    empty=$((width - filled))
    bar=$(printf '%*s' "$filled" '' | tr ' ' '━')
    bar="$bar$(printf '%*s' "$empty" '' | tr ' ' '─')"
    draw_header "Transaction in progress"
    printf '\n  %s%s%s\n\n' "$C_BOLD" "$phase" "$C_RESET"
    printf '  %s%s%s  %3s%%\n' "$C_CYAN" "$bar" "$C_RESET" "$percent"
    printf '\n  %s%s%s\n' "$C_DIM" "$detail" "$C_RESET"
    printf '\n  %sDo not disconnect the target disk.%s\n' "$C_YELLOW" "$C_RESET"
}

show_result() {
    local success="$1" message="$2"
    draw_header "Operation result"
    if [ "$success" = "1" ]; then
        printf '\n  %s✓ %s%s\n' "$C_GREEN" "$message" "$C_RESET"
    else
        printf '\n  %s✗ %s%s\n' "$C_RED" "$message" "$C_RESET"
    fi
    printf '\n  %sPress any key to continue%s' "$C_DIM" "$C_RESET"
    read_key >/dev/null
}

load_folder_menu() {
    local mode="$1" size status path name marker
    MENU_LABELS=() MENU_VALUES=()
    while IFS=$'\t' read -r size status path; do
        [ -n "$path" ] || continue
        if [ "$mode" = "local" ] && [ "$status" != "local" ]; then continue; fi
        if [ "$mode" = "offloaded" ] && [ "$status" != "offloaded" ]; then continue; fi
        name=$(/usr/bin/basename "$path")
        if [ "$status" = "offloaded" ]; then marker="OFFLOADED"; else marker="LOCAL"; fi
        MENU_LABELS+=("$(printf '%-38s %10s  %s' "$name" "$(human_bytes "$size")" "$marker")")
        MENU_VALUES+=("$path")
    done < <(list_folders | /usr/bin/sort -t $'\t' -k1,1nr)
}

load_volume_menu() {
    local excluded_destination="${1:-}" free path name
    MENU_LABELS=() MENU_VALUES=()
    while IFS=$'\t' read -r free path; do
        [ -n "$path" ] || continue
        if [ -n "$excluded_destination" ]; then
            case "$excluded_destination" in "$path"/*) continue ;; esac
        fi
        name=$(/usr/bin/basename "$path")
        MENU_LABELS+=("$(printf '%-42s %12s free' "$name" "$(human_bytes "$free")")")
        MENU_VALUES+=("$path")
    done < <(list_external_volumes)
}

record_action() {
    local verb="$1" name="$2" delta="$3"
    SESSION_DELTA=$((SESSION_DELTA + delta))
    if [ "$delta" -ge 0 ]; then
        SESSION_ACTIONS+=("$verb $name — $(human_bytes "$delta") saved locally")
    else
        SESSION_ACTIONS+=("$verb $name — $(human_bytes "$((0 - delta))") additionally consumed locally")
    fi
}

tui_offload() {
    local source target name size
    load_folder_menu local
    if [ "${#MENU_VALUES[@]}" -eq 0 ]; then show_result 0 "No local folders are available to offload."; return; fi
    menu_select "Choose a folder to offload" "↑/↓ navigate  •  Enter select  •  q back" || return
    source="$SELECTED_VALUE"; name=$(/usr/bin/basename "$source"); size=$(path_bytes "$source")
    load_volume_menu
    if [ "${#MENU_VALUES[@]}" -eq 0 ]; then show_result 0 "No writable external volumes are mounted."; return; fi
    menu_select "Choose the target disk" "↑/↓ navigate  •  Enter select  •  q back" || return
    target="$SELECTED_VALUE"
    confirm_action "Confirm offload" "Move $name ($(human_bytes "$size")) to $(/usr/bin/basename "$target")?" "The source is removed only after a complete SHA-256 verification." || return
    if offload_folder "$source" "$target"; then
        record_action "Offloaded" "$name" "$LAST_LOCAL_DELTA_BYTES"
        show_result 1 "$name is now safely offloaded."
    else
        show_result 0 "$APPOFFLOAD_ERROR"
    fi
}

tui_restore_source() {
    local source="$1" name size destination
    name=$(/usr/bin/basename "$source")
    destination=$(managed_link_destination "$source"); size=$(path_bytes "$destination")
    confirm_action "Confirm restore" "Restore $name ($(human_bytes "$size")) to the local disk?" "The external copy is removed only after local SHA-256 verification." || return
    if restore_folder "$source"; then
        record_action "Restored" "$name" "$LAST_LOCAL_DELTA_BYTES"
        show_result 1 "$name is now back on the local disk."
    else
        show_result 0 "$APPOFFLOAD_ERROR"
    fi
}

tui_move_offload_source() {
    local source="$1" name destination target size
    name=$(/usr/bin/basename "$source")
    destination=$(managed_link_destination "$source") || { show_result 0 "The current offload destination is unavailable."; return; }
    size=$(path_bytes "$destination")
    load_volume_menu "$destination"
    if [ "${#MENU_VALUES[@]}" -eq 0 ]; then show_result 0 "No other writable external volume is mounted."; return; fi
    menu_select "Move $name to another disk" "↑/↓ navigate  •  Enter select  •  q back" || return
    target="$SELECTED_VALUE"
    confirm_action "Confirm offload move" "Move $name ($(human_bytes "$size")) to $(/usr/bin/basename "$target")?" "The old external copy is removed only after the new copy is SHA-256 verified and active." || return
    if move_offload "$source" "$target"; then
        SESSION_ACTIONS+=("Moved offload $name — $(human_bytes "$LAST_EXTERNAL_BYTES") transferred; local disk unchanged")
        show_result 1 "$name now uses $(/usr/bin/basename "$target")."
    else
        show_result 0 "$APPOFFLOAD_ERROR"
    fi
}

confirm_permanent_delete() {
    local name="$1" response
    draw_header "Permanently delete offload"
    printf '\n  %sThis permanently deletes all offloaded data for %s.%s\n' "$C_RED" "$name" "$C_RESET"
    printf '  There is no local copy and this cannot be undone.\n\n'
    printf '  Type %sDELETE%s to continue: ' "$C_BOLD" "$C_RESET"
    printf '\033[?25h'
    IFS= read -r response
    printf '\033[?25l'
    [ "$response" = "DELETE" ]
}

tui_delete_offload_source() {
    local source="$1" name destination size
    name=$(/usr/bin/basename "$source")
    destination=$(managed_link_destination "$source") || { show_result 0 "The offload destination is unavailable."; return; }
    size=$(path_bytes "$destination")
    confirm_permanent_delete "$name" || return
    if delete_offload "$source"; then
        SESSION_ACTIONS+=("Deleted offload $name — $(human_bytes "$LAST_EXTERNAL_BYTES") removed externally; local disk unchanged")
        show_result 1 "$name and its managed link were permanently deleted."
    else
        show_result 0 "$APPOFFLOAD_ERROR"
    fi
}

tui_manage_offloads() {
    local source name action
    while true; do
        load_folder_menu offloaded
        if [ "${#MENU_VALUES[@]}" -eq 0 ]; then show_result 0 "No managed offloads are available."; return; fi
        menu_select "Manage offloads" "↑/↓ navigate  •  Enter manage  •  q back" || return
        source="$SELECTED_VALUE"
        name=$(/usr/bin/basename "$source")
        MENU_LABELS=("Restore to the local disk" "Move to another external disk" "Permanently delete offloaded data" "Back to offload list")
        MENU_VALUES=("restore" "move" "delete" "back")
        menu_select "Manage $name" "↑/↓ navigate  •  Enter select  •  q back" || continue
        action="$SELECTED_VALUE"
        case "$action" in
            restore) tui_restore_source "$source" ;;
            move) tui_move_offload_source "$source" ;;
            delete) tui_delete_offload_source "$source" ;;
            back) continue ;;
        esac
    done
}

tui_inventory() {
    local size status path name color total_local total_offloaded report height status_rows limit total_count shown_count
    report=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/appoffload-inventory.XXXXXX") || return
    list_folders | /usr/bin/sort -t $'\t' -k1,1nr > "$report"
    refresh_disk_status
    height=$(terminal_height); status_rows=$(status_bar_rows); limit=$((height - status_rows - 9))
    [ "$limit" -lt 2 ] && limit=2
    total_local=$(/usr/bin/awk -F '\t' '$2 == "local" {sum += $1} END {printf "%.0f", sum+0}' "$report")
    total_offloaded=$(/usr/bin/awk -F '\t' '$2 == "offloaded" {sum += $1} END {printf "%.0f", sum+0}' "$report")
    total_count=$(/usr/bin/awk 'END {print NR+0}' "$report")
    shown_count=$total_count; [ "$shown_count" -gt "$limit" ] && shown_count=$limit
    draw_header "Application Support inventory"
    printf '\n  %-40s %12s  %s\n' "FOLDER" "SIZE" "LOCATION"
    printf '  %-40s %12s  %s\n' "────────────────────────────────────────" "────────────" "──────────"
    while IFS=$'\t' read -r size status path; do
        name=$(/usr/bin/basename "$path")
        if [ "$status" = "offloaded" ]; then color="$C_GREEN"; else color="$C_RESET"; fi
        printf '  %-40s %12s  %s%s%s\n' "$(truncate_text "$name" 40)" "$(human_bytes "$size")" "$color" "$status" "$C_RESET"
    done < <(/usr/bin/head -n "$limit" "$report")
    printf '\n  %sLocal: %s  •  Offloaded: %s%s\n' "$C_BOLD" "$(human_bytes "$total_local")" "$(human_bytes "$total_offloaded")" "$C_RESET"
    [ "$shown_count" -lt "$total_count" ] && printf '  %sShowing %d of %d folders; enlarge the window to see more.%s\n' "$C_DIM" "$shown_count" "$total_count" "$C_RESET"
    printf '\n  %sPress any key to continue%s' "$C_DIM" "$C_RESET"
    read_key >/dev/null
    /bin/rm -f "$report"
}

tui_app_audit() {
    local report sorted size classification evidence path name color label
    local installed recommended review related system offloaded height status_rows limit total_count shown_count
    report=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/appoffload-audit-report.XXXXXX") || return
    sorted="${report}.sorted"
    draw_header "Scanning installed apps"
    printf '\n  %sReading app bundle identifiers and comparing support folders…%s\n' "$C_CYAN" "$C_RESET"
    if ! audit_folders > "$report"; then
        /bin/rm -f "$report"
        show_result 0 "The installed-app audit could not be completed."
        return
    fi
    installed=$(/usr/bin/awk -F '\t' '$2 == "installed" {n++} END {print n+0}' "$report")
    recommended=$(/usr/bin/awk -F '\t' '$2 == "recommend" {n++} END {print n+0}' "$report")
    review=$(/usr/bin/awk -F '\t' '$2 == "review" {n++} END {print n+0}' "$report")
    related=$(/usr/bin/awk -F '\t' '$2 == "related" {n++} END {print n+0}' "$report")
    system=$(/usr/bin/awk -F '\t' '$2 == "system" {n++} END {print n+0}' "$report")
    offloaded=$(/usr/bin/awk -F '\t' '$2 == "offloaded" {n++} END {print n+0}' "$report")
    /usr/bin/awk -F '\t' 'BEGIN {OFS="\t"}
        $2 == "recommend" {rank=1}
        $2 == "review" {rank=2}
        $2 == "installed" {rank=3}
        $2 == "related" {rank=4}
        $2 == "system" {rank=5}
        $2 == "offloaded" {rank=6}
        {print rank, $0}
    ' "$report" | /usr/bin/sort -t $'\t' -k1,1n -k2,2nr | /usr/bin/cut -f2- > "$sorted"
    refresh_disk_status
    height=$(terminal_height); status_rows=$(status_bar_rows); limit=$((height - status_rows - 10))
    [ "$limit" -lt 2 ] && limit=2
    total_count=$(/usr/bin/awk 'END {print NR+0}' "$sorted")
    shown_count=$total_count; [ "$shown_count" -gt "$limit" ] && shown_count=$limit

    draw_header "Installed apps vs. Application Support"
    printf '\n  %-34s %10s  %-11s %s\n' "FOLDER" "SIZE" "ASSESSMENT" "MATCH / REASON"
    printf '  %-34s %10s  %-11s %s\n' "──────────────────────────────────" "──────────" "───────────" "────────────────────"
    while IFS=$'\t' read -r size classification evidence path; do
        [ -n "$path" ] || continue
        name=$(/usr/bin/basename "$path")
        case "$classification" in
            recommend) color="$C_YELLOW"; label="RECOMMEND" ;;
            installed) color="$C_GREEN"; label="INSTALLED" ;;
            related) color="$C_BLUE"; label="RELATED" ;;
            system) color="$C_DIM"; label="SYSTEM" ;;
            offloaded) color="$C_BLUE"; label="OFFLOADED" ;;
            *) color="$C_DIM"; label="REVIEW" ;;
        esac
        printf '  %-34s %10s  %s%-11s%s %s\n' \
            "$(truncate_text "$name" 34)" "$(human_bytes "$size")" "$color" "$label" "$C_RESET" "$(truncate_text "$evidence" 27)"
    done < <(/usr/bin/head -n "$limit" "$sorted")
    printf '\n  %s%d recommendation(s)%s  •  %d installed  •  %d related  •  %d unresolved  •  %d system  •  %d offloaded\n' \
        "$C_YELLOW" "$recommended" "$C_RESET" "$installed" "$related" "$review" "$system" "$offloaded"
    printf '  %sOnly high-confidence orphan candidates are recommended; REVIEW is not a deletion claim.%s\n' "$C_DIM" "$C_RESET"
    [ "$shown_count" -lt "$total_count" ] && printf '  %sShowing %d of %d results; enlarge the window to see more.%s\n' "$C_DIM" "$shown_count" "$total_count" "$C_RESET"
    printf '\n  %sPress any key to continue%s' "$C_DIM" "$C_RESET"
    read_key >/dev/null
    /bin/rm -f "$report" "$sorted"
}

load_custom_root_menu() {
    local kind status path marker
    MENU_LABELS=() MENU_VALUES=()
    while IFS=$'\t' read -r kind status path; do
        [ "$kind" = "custom" ] || continue
        [ "$status" = "available" ] && marker="available" || marker="not mounted"
        MENU_LABELS+=("$(printf '%-56s %s' "$(truncate_text "$path" 56)" "$marker")")
        MENU_VALUES+=("$path")
    done < <(list_app_roots)
}

tui_add_app_root() {
    local path
    draw_header "Add installed-app search location"
    printf '\n  Enter an absolute folder path. The folder may contain .app bundles\n'
    printf '  directly or in nested subfolders.\n\n'
    printf '  %sPath:%s ' "$C_BOLD" "$C_RESET"
    printf '\033[?25h'
    IFS= read -r path
    printf '\033[?25l'
    [ -n "$path" ] || return
    if add_app_root "$path" >/dev/null; then
        show_result 1 "Added app search location: $LAST_APP_ROOT"
    else
        show_result 0 "$APPOFFLOAD_ERROR"
    fi
}

tui_remove_app_root() {
    local path
    load_custom_root_menu
    if [ "${#MENU_VALUES[@]}" -eq 0 ]; then
        show_result 0 "No custom app search locations are configured."
        return
    fi
    menu_select "Remove a custom app search location" "↑/↓ navigate  •  Enter select  •  q back" || return
    path="$SELECTED_VALUE"
    confirm_action "Remove search location" "Stop scanning $path?" "No apps or files in that folder will be changed." || return
    if remove_app_root "$path"; then
        show_result 1 "Removed app search location: $path"
    else
        show_result 0 "$APPOFFLOAD_ERROR"
    fi
}

tui_show_app_roots() {
    local kind status path color label report height status_rows limit total_count shown_count
    report=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/appoffload-roots.XXXXXX") || return
    list_app_roots > "$report"
    refresh_disk_status
    height=$(terminal_height); status_rows=$(status_bar_rows); limit=$((height - status_rows - 10))
    [ "$limit" -lt 2 ] && limit=2
    total_count=$(/usr/bin/awk 'END {print NR+0}' "$report")
    shown_count=$total_count; [ "$shown_count" -gt "$limit" ] && shown_count=$limit
    draw_header "Installed-app search locations"
    printf '\n  %-10s %-13s %s\n' "TYPE" "STATUS" "FOLDER"
    printf '  %-10s %-13s %s\n' "──────────" "─────────────" "────────────────────────────────────────"
    while IFS=$'\t' read -r kind status path; do
        if [ "$status" = "available" ]; then color="$C_GREEN"; label="available"; else color="$C_YELLOW"; label="not mounted"; fi
        printf '  %-10s %s%-13s%s %s\n' "$kind" "$color" "$label" "$C_RESET" "$(truncate_text "$path" 50)"
    done < <(/usr/bin/head -n "$limit" "$report")
    [ "$shown_count" -lt "$total_count" ] && printf '  %sShowing %d of %d locations; enlarge the window to see more.%s\n' "$C_DIM" "$shown_count" "$total_count" "$C_RESET"
    printf '\n  %sUnavailable custom locations remain saved and are scanned when mounted.%s\n' "$C_DIM" "$C_RESET"
    printf '\n  %sPress any key to continue%s' "$C_DIM" "$C_RESET"
    read_key >/dev/null
    /bin/rm -f "$report"
}

tui_manage_app_roots() {
    local action
    while true; do
        MENU_LABELS=("View configured locations" "Add a search location" "Remove a custom location" "Back to main menu")
        MENU_VALUES=("view" "add" "remove" "back")
        menu_select "Manage installed-app search locations" "↑/↓ navigate  •  Enter select  •  q back" || return
        action="$SELECTED_VALUE"
        case "$action" in
            view) tui_show_app_roots ;;
            add) tui_add_app_root ;;
            remove) tui_remove_app_root ;;
            back) return ;;
        esac
    done
}

tui_health_center() {
    local report severity status name source destination detail action index selected issues healthy result
    local health_sources=() health_destinations=() health_details=() health_actions=() health_statuses=()
    while true; do
        report=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/appoffload-health.XXXXXX") || return
        draw_header "Scanning offload health"
        printf '\n  %sChecking links, target identities, transactions, and rollback artifacts…%s\n' "$C_CYAN" "$C_RESET"
        health_scan > "$report"
        issues=$(/usr/bin/awk -F '\t' '$1 != "ok" {n++} END {print n+0}' "$report")
        healthy=$(/usr/bin/awk -F '\t' '$1 == "ok" {n++} END {print n+0}' "$report")
        MENU_LABELS=() MENU_VALUES=()
        health_sources=() health_destinations=() health_details=() health_actions=() health_statuses=()
        index=0
        while IFS=$'\t' read -r severity status name source destination detail action; do
            [ -n "$status" ] || continue
            case "$severity" in ok) result="OK" ;; critical) result="CRITICAL" ;; *) result="WARNING" ;; esac
            MENU_LABELS+=("$(printf '%-10s %-24s %s' "$result" "$(truncate_text "$name" 24)" "$detail")")
            MENU_VALUES+=("$index")
            health_sources+=("$source")
            health_destinations+=("$destination")
            health_details+=("$detail")
            health_actions+=("$action")
            health_statuses+=("$status")
            index=$((index + 1))
        done < <(/usr/bin/awk -F '\t' 'BEGIN {OFS="\t"} $1 == "critical" {rank=1} $1 == "warning" {rank=2} $1 == "ok" {rank=3} {print rank, $0}' "$report" | /usr/bin/sort -t $'\t' -k1,1n | /usr/bin/cut -f2-)
        /bin/rm -f "$report"
        if [ "${#MENU_VALUES[@]}" -eq 0 ]; then
            show_result 1 "No registered offloads or recovery artifacts were found."
            return
        fi
        menu_select "Health and Repair — $issues issue(s), $healthy healthy" "↑/↓ navigate  •  Enter inspect/repair  •  q back" || return
        selected="$SELECTED_VALUE"
        source=${health_sources[$selected]}
        destination=${health_destinations[$selected]}
        detail=${health_details[$selected]}
        action=${health_actions[$selected]}
        status=${health_statuses[$selected]}
        case "$action" in
            repair-link)
                confirm_action "Repair managed link" "$detail" "Retarget the link to $destination? No app data will be copied or deleted." || continue
                if repair_offload_link "$source"; then show_result 1 "Managed link repaired and registry updated."; else show_result 0 "$APPOFFLOAD_ERROR"; fi
                ;;
            forget-record)
                confirm_action "Remove stale health record" "$detail" "The local folder and external data will not be changed." || continue
                if remove_offload_record "$source"; then show_result 1 "Stale registry record removed."; else show_result 0 "$APPOFFLOAD_ERROR"; fi
                ;;
            clean-staging)
                confirm_action "Remove stale staging data" "$detail" "Delete this incomplete copy: $source" || continue
                if clean_health_staging "$source"; then show_result 1 "Stale staging data removed."; else show_result 0 "$APPOFFLOAD_ERROR"; fi
                ;;
            recover-backup)
                confirm_action "Recover local rollback copy" "$detail" "Restore it to $destination?" || continue
                if recover_local_backup "$source"; then show_result 1 "Local rollback copy restored."; else show_result 0 "$APPOFFLOAD_ERROR"; fi
                ;;
            recover-transaction)
                confirm_action "Recover interrupted transaction" "$detail" "Restore rollback data and remove incomplete staging when safe?" || continue
                if recover_incomplete_transaction "$source"; then show_result 1 "Interrupted transaction recovered."; else show_result 0 "$APPOFFLOAD_ERROR"; fi
                ;;
            *)
                if [ "$status" = "healthy" ]; then show_result 1 "$detail — $destination"; else show_result 0 "$detail — $destination"; fi
                ;;
        esac
    done
}

load_migratable_app_menu() {
    local size name identifier path offload_count offload_bytes badge rank apps report augmented
    MENU_LABELS=() MENU_VALUES=()
    apps=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/appoffload-app-picker.XXXXXX") || return
    report="${apps}.offloads"; augmented="${apps}.sorted"
    : > "$report"; : > "$augmented"
    list_migratable_apps > "$apps"; list_managed_migration_offloads > "$report"
    while IFS=$'\t' read -r size name identifier path; do
        [ -n "$path" ] || continue
        IFS=$'\t' read -r offload_count offload_bytes <<< "$(migration_offload_totals "$name" "$identifier" "$report")"
        if [ "$offload_count" -gt 0 ]; then rank=0; badge="OFFLOADED $(human_bytes "$offload_bytes")"; else rank=1; badge=""; fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$rank" "$name" "$size" "$identifier" "$path" "$offload_count" "$offload_bytes" >> "$augmented"
    done < "$apps"
    while IFS=$'\t' read -r rank name size identifier path offload_count offload_bytes; do
        if [ "$offload_count" -gt 0 ]; then badge="OFFLOADED $(human_bytes "$offload_bytes")"; else badge=""; fi
        MENU_LABELS+=("$(printf '%-25s %9s app  %-19s %s' "$(truncate_text "$name" 25)" "$(human_bytes "$size")" "$badge" "$identifier")")
        MENU_VALUES+=("$path")
    done < <(/usr/bin/sort -t $'\t' -k1,1n -k2,2f "$augmented")
    /bin/rm -f "$apps" "$report" "$augmented"
}

load_migration_backup_menu() {
    local size name identifier created path
    MENU_LABELS=() MENU_VALUES=()
    while IFS=$'\t' read -r size name identifier created path; do
        [ -n "$path" ] || continue
        MENU_LABELS+=("$(printf '%-28s %10s  %s' "$(truncate_text "$name" 28)" "$(human_bytes "$size")" "$created")")
        MENU_VALUES+=("$path")
    done < <(list_app_migration_backups | /usr/bin/sort -t $'\t' -k4,4r)
}

tui_create_app_migration() {
    local app target report count total name size category relative source offloaded=0
    load_migratable_app_menu
    if [ "${#MENU_VALUES[@]}" -eq 0 ]; then show_result 0 "No installed apps were found in the configured search locations."; return; fi
    menu_select "Choose an app — managed offloads shown first" "↑/↓ navigate  •  Enter scan  •  q back" || return
    app="$SELECTED_VALUE"; name=$(/usr/bin/basename "$app" .app)
    report=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/appoffload-migration-preview.XXXXXX") || return
    draw_header "Discovering data associated with $name"
    printf '\n  %sScanning the app bundle and user Library locations…%s\n' "$C_CYAN" "$C_RESET"
    if ! app_migration_inventory "$app" > "$report"; then /bin/rm -f "$report"; show_result 0 "$APPOFFLOAD_ERROR"; return; fi
    count=$(/usr/bin/awk 'END {print NR+0}' "$report"); total=$(/usr/bin/awk -F '\t' '{sum += $1} END {printf "%.0f", sum+0}' "$report")
    while IFS=$'\t' read -r size category relative source; do [ "$(migration_source_kind "$source")" = "OFFLOADED" ] && offloaded=$((offloaded + 1)); done < "$report"
    /bin/rm -f "$report"
    load_volume_menu
    if [ "${#MENU_VALUES[@]}" -eq 0 ]; then show_result 0 "No writable external volumes are mounted."; return; fi
    menu_select "Choose the migration-backup disk" "↑/↓ navigate  •  Enter select  •  q back" || return
    target="$SELECTED_VALUE"
    confirm_action "Confirm complete-app backup" "$name: $count items, $(human_bytes "$total"); $offloaded offload(s) will be materialized" "Copy to $(/usr/bin/basename "$target") and keep all originals unchanged?" || return
    if create_app_migration_backup "$app" "$target"; then
        SESSION_ACTIONS+=("Backed up $LAST_MIGRATION_APP_NAME for migration — $(human_bytes "$LAST_EXTERNAL_BYTES") copied; local disk unchanged")
        show_result 1 "$LAST_MIGRATION_APP_NAME and $LAST_MIGRATION_ITEM_COUNT items were verified."
    else show_result 0 "$APPOFFLOAD_ERROR"; fi
}

tui_restore_app_migration() {
    local backup="${1:-}"
    if [ -z "$backup" ]; then
        load_migration_backup_menu
        if [ "${#MENU_VALUES[@]}" -eq 0 ]; then show_result 0 "No complete-app migration backups were found on mounted disks."; return; fi
        menu_select "Choose a complete-app backup to restore" "↑/↓ navigate  •  Enter select  •  q back" || return
        backup="$SELECTED_VALUE"
    fi
    confirm_action "Confirm complete-app restore" "Verify and restore this app plus all discovered user Library data?" "Existing files are never overwritten; the backup remains on the removable disk." || return
    if restore_app_migration_source "$backup" ""; then
        record_action "Restored migration backup for" "$LAST_MIGRATION_APP_NAME" "$LAST_LOCAL_DELTA_BYTES"
        show_result 1 "$LAST_MIGRATION_APP_NAME and $LAST_MIGRATION_ITEM_COUNT items were restored."
    else show_result 0 "$APPOFFLOAD_ERROR"; fi
}

tui_verify_app_migration() {
    local backup="${1:-}"
    if [ -z "$backup" ]; then
        load_migration_backup_menu
        if [ "${#MENU_VALUES[@]}" -eq 0 ]; then show_result 0 "No complete-app migration backups were found on mounted disks."; return; fi
        menu_select "Choose a complete-app backup to verify" "↑/↓ navigate  •  Enter verify  •  q back" || return
        backup="$SELECTED_VALUE"
    fi
    draw_header "Verifying complete-app backup"
    printf '\n  %sRecomputing SHA-256 checksums for the entire portable package…%s\n' "$C_CYAN" "$C_RESET"
    if verify_app_migration_source "$backup"; then show_result 1 "Every item in the migration backup matches its manifest."; else show_result 0 "$APPOFFLOAD_ERROR"; fi
}

tui_move_app_migration() {
    local backup="$1" target name
    name=$(/usr/bin/basename "$backup")
    load_volume_menu "$backup"
    if [ "${#MENU_VALUES[@]}" -eq 0 ]; then show_result 0 "No other writable destination is mounted."; return; fi
    menu_select "Move migration backup" "↑/↓ navigate  •  Enter select  •  q back" || return
    target="$SELECTED_VALUE"
    confirm_action "Confirm backup move" "Move $name to $(/usr/bin/basename "$target")?" "The original is removed only after the destination is fully verified." || return
    if move_app_migration_backup "$backup" "$target"; then
        SESSION_ACTIONS+=("Moved migration backup for $LAST_MIGRATION_APP_NAME — verified; local disk unchanged")
        show_result 1 "Backup moved and verified at $LAST_MIGRATION_BACKUP"
    else show_result 0 "$APPOFFLOAD_ERROR"; fi
}

confirm_migration_backup_delete() {
    local name="$1" response
    draw_header "Permanently delete migration backup"
    printf '\n  %sThis permanently deletes the migration backup for %s.%s\n' "$C_RED" "$name" "$C_RESET"
    printf '  Installed apps and current Library data are not changed.\n\n'
    printf '  Type %sDELETE%s to continue: ' "$C_BOLD" "$C_RESET"
    printf '\033[?25h'; IFS= read -r response; printf '\033[?25l'
    [ "$response" = "DELETE" ]
}

tui_delete_app_migration() {
    local backup="$1" name
    name=$(/usr/bin/basename "$backup")
    confirm_migration_backup_delete "$name" || return
    if delete_app_migration_backup "$backup"; then
        SESSION_ACTIONS+=("Deleted migration backup for $LAST_MIGRATION_APP_NAME — $(human_bytes "$LAST_EXTERNAL_BYTES") removed externally")
        show_result 1 "Migration backup permanently deleted."
    else show_result 0 "$APPOFFLOAD_ERROR"; fi
}

tui_manage_app_migrations() {
    local backup name action
    while true; do
        load_migration_backup_menu
        if [ "${#MENU_VALUES[@]}" -eq 0 ]; then show_result 0 "No complete-app migration backups were found on mounted disks."; return; fi
        menu_select "Manage migration backups" "↑/↓ navigate  •  Enter manage  •  q back" || return
        backup="$SELECTED_VALUE"; name=$(/usr/bin/basename "$backup")
        MENU_LABELS=("Restore app and user Library data" "Move backup to another destination" "Verify backup integrity" "Permanently delete backup" "Back to backup list")
        MENU_VALUES=("restore" "move" "verify" "delete" "back")
        menu_select "Manage $(truncate_text "$name" 46)" "↑/↓ navigate  •  Enter select  •  q back" || continue
        action="$SELECTED_VALUE"
        case "$action" in restore) tui_restore_app_migration "$backup" ;; move) tui_move_app_migration "$backup" ;; verify) tui_verify_app_migration "$backup" ;; delete) tui_delete_app_migration "$backup" ;; back) continue ;; esac
    done
}

tui_app_migration() {
    local action
    while true; do
        MENU_LABELS=("Create a complete-app migration backup" "Manage existing migration backups" "Back to main menu")
        MENU_VALUES=("backup" "manage" "back")
        menu_select "Complete-app migration" "↑/↓ navigate  •  Enter select  •  q back" || return
        action="$SELECTED_VALUE"
        case "$action" in backup) tui_create_app_migration ;; manage) tui_manage_app_migrations ;; back) return ;; esac
    done
}

print_session_summary() {
    local action
    printf '\n%sSession summary%s\n' "$C_BOLD" "$C_RESET"
    if [ "${#SESSION_ACTIONS[@]}" -eq 0 ]; then
        printf '  No folders were moved. Local disk usage is unchanged.\n'
    else
        for action in "${SESSION_ACTIONS[@]}"; do printf '  • %s\n' "$action"; done
        if [ "$SESSION_DELTA" -gt 0 ]; then
            printf '  %sNet local space saved: %s%s\n' "$C_GREEN" "$(human_bytes "$SESSION_DELTA")" "$C_RESET"
        elif [ "$SESSION_DELTA" -lt 0 ]; then
            printf '  %sNet additional local space consumed: %s%s\n' "$C_YELLOW" "$(human_bytes "$((0 - SESSION_DELTA))")" "$C_RESET"
        else
            printf '  Net local disk change: 0 B\n'
        fi
    fi
}

run_tui() {
    local action
    tui_enter
    while true; do
        MENU_LABELS=(
            "Offload a local Application Support folder"
            "Manage existing offloads"
            "Back up or restore a complete app"
            "Health and repair center"
            "Scan Application Support folders and sizes"
            "Compare installed apps and get recommendations"
            "Manage installed-app search locations"
            "Quit"
        )
        MENU_VALUES=("offload" "manage" "migration" "health" "inventory" "audit" "locations" "quit")
        menu_select "Move large app data off your local disk—safely" "↑/↓ navigate  •  Enter select  •  q quit" || break
        action="$SELECTED_VALUE"
        case "$action" in
            offload) tui_offload ;;
            manage) tui_manage_offloads ;;
            migration) tui_app_migration ;;
            health) tui_health_center ;;
            inventory) tui_inventory ;;
            audit) tui_app_audit ;;
            locations) tui_manage_app_roots ;;
            quit) break ;;
        esac
    done
    tui_cleanup
    trap - INT TERM
    print_session_summary
}
