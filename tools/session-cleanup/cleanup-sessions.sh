#!/usr/bin/env bash
# Moves "empty" Claude Code sessions (small transcripts) and redundant duplicate copies into a trash
# folder and purges trash entries past retention. Bash port of cleanup-sessions.ps1 — see that file
# for the full phase descriptions. Desired-state and idempotent: re-runs only act on sessions that
# currently match the criteria.
set -euo pipefail

MAX_SIZE_BYTES=$((250 * 1024))
# Never touch sessions with activity within this window (0 = no age guard). Sessions worth keeping
# carry a /rename title and are protected regardless of age.
MIN_AGE_HOURS=0
RETENTION_DAYS=30
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --max-size-bytes) MAX_SIZE_BYTES=$2; shift 2 ;;
        --min-age-hours)  MIN_AGE_HOURS=$2; shift 2 ;;
        --retention-days) RETENTION_DAYS=$2; shift 2 ;;
        --dry-run)        DRY_RUN=1; shift ;;
        *) echo "usage: cleanup-sessions.sh [--max-size-bytes N] [--min-age-hours N] [--retention-days N] [--dry-run]" >&2; exit 2 ;;
    esac
done

PROJECTS_DIR="$HOME/.claude/projects"
TRASH_DIR="$HOME/.claude/projects-trash"
LOG_FILE="$TRASH_DIR/cleanup.log"

[ -d "$PROJECTS_DIR" ] || { echo "No projects directory at $PROJECTS_DIR - nothing to do."; exit 0; }
mkdir -p "$TRASH_DIR"

log_lines=""
log() {
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') $1"
    log_lines="${log_lines}${line}
"
    echo "$line"
}

now=$(date +%s)
today_batch="$TRASH_DIR/$(date +%Y-%m-%d)"

# Last activity of a transcript: the newest inner "timestamp" beats the file mtime, because resume
# pickers, cloud bridges and sync tools touch files without adding content - mtime alone would
# re-protect old sessions forever. Files without inner timestamps (bridge stubs) fall back to mtime.
last_activity_epoch() {
    local f="$1" ts epoch
    ts=$(tail -c 262144 "$f" | grep -oE '"timestamp"[[:space:]]*:[[:space:]]*"[^"]+"' | tail -1 | sed -E 's/.*"([^"]+)"$/\1/') || true
    if [ -n "$ts" ] && epoch=$(date -d "$ts" +%s 2>/dev/null); then
        echo "$epoch"
    else
        stat -c %Y "$f"
    fi
}

# Moves a transcript plus its sidecar directory into today's trash batch. A locked/failed move means
# the session is open right now and is left alone.
trash_session() {
    local transcript="$1" label="$2"
    local project_name session_id sidecar target
    project_name=$(basename "$(dirname "$transcript")")
    session_id=$(basename "$transcript" .jsonl)
    sidecar="$(dirname "$transcript")/$session_id"
    target="$today_batch/$project_name"
    mkdir -p "$target"
    if mv -f "$transcript" "$target/"; then
        if [ -d "$sidecar" ]; then
            rm -rf "$target/$session_id"
            mv -f "$sidecar" "$target/"
        fi
        log "trashed $project_name/$(basename "$transcript") ($label)"
        return 0
    fi
    log "skipped $project_name/$(basename "$transcript"): move failed"
    return 1
}

# Human-readable session label: the first real user message (what the resume picker shows). Injected
# meta messages (caveats, command wrappers, hook feedback, keepwarm ticks) are skipped.
session_title() {
    local f="$1" line content
    while IFS= read -r line; do
        case "$line" in *'"type"'*'"user"'*) ;; *) continue ;; esac
        content=$(printf '%s' "$line" | grep -oE '"content"[[:space:]]*:[[:space:]]*"(\\.|[^"\\])*"' | head -1 | sed -E 's/^"content"[[:space:]]*:[[:space:]]*"//; s/"$//')
        [ -n "$content" ] || continue
        case "$content" in Caveat:*|'<'*|'[keepwarm-tick]'*|'Stop hook feedback:'*) continue ;; esac
        content=$(printf '%s' "$content" | tr -s '[:space:]' ' ')
        if [ "${#content}" -gt 60 ]; then content="${content:0:57}..."; fi
        printf '%s' "$content"
        return
    done < <(head -n 50 "$f")
    printf '(no user message)'
}

# Timestamp of the last entry two diverged copies still share - the fork happened after this moment.
fork_point() {
    local a="$1" b="$2" out byte common ts
    out=$(cmp -- "$a" "$b" 2>&1) || true
    byte=$(printf '%s' "$out" | grep -oE 'byte [0-9]+' | head -1 | grep -oE '[0-9]+') || true
    [ -n "$byte" ] || return 0
    # "differ: byte N" is the 1-based first difference; "EOF ... after byte N" means N common bytes.
    common=$byte
    case "$out" in *differ:*) common=$((byte - 1)) ;; esac
    [ "$common" -gt 0 ] || return 0
    ts=$(head -c "$common" "$a" | grep -oE '"timestamp"[[:space:]]*:[[:space:]]*"[^"]+"' | tail -1 | sed -E 's/.*"([^"]+)"$/\1/') || true
    [ -n "$ts" ] || return 0
    date -d "$ts" '+%Y-%m-%d %H:%M' 2>/dev/null || true
}

# Liveness per project dir - among equal-content copies the copy in the dir the user works in today
# must survive, or the session disappears from the resume picker. Neither the cwd recorded inside a
# copy (may point one or two migrations back) nor the file mtime (touched by pickers and sync tools)
# identifies the current location. The munged dir name itself is the only ground truth: walk existing
# directories from the filesystem root and match munged component names to see whether the dir still
# corresponds to an openable path. Munged names are ambiguous ("-" may be "/", " ", "." ...), so
# every child whose munged name is a component prefix of the remainder is followed.
live_walk() {
    local cur="$1" rest="$2" child base m
    while IFS= read -r child; do
        base=$(basename "$child")
        m=$(printf '%s' "$base" | sed 's/[^A-Za-z0-9]/-/g')
        if [ "$rest" = "$m" ]; then return 0; fi
        case "$rest" in
            "$m"-*) live_walk "$child" "${rest#"$m"-}" && return 0 ;;
        esac
    done < <(find "$cur" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    return 1
}
declare -A dir_live_cache
is_live_project_dir() {
    local name="$1"
    if [ -z "${dir_live_cache[$name]+x}" ]; then
        # Absolute Linux paths munge to a leading "-" (/home/... -> -home-...).
        if [ "${name#-}" != "$name" ] && live_walk / "${name#-}"; then
            dir_live_cache[$name]=1
        else
            dir_live_cache[$name]=0
        fi
    fi
    [ "${dir_live_cache[$name]}" = 1 ]
}

# --- Phase 1: duplicate copies of the same session across project dirs -------------------------------
# Tree moves keep the old-path copy (transfer-cc-sessions). A copy that is byte-identical to - or a
# strict prefix of - the kept copy carries no extra information and goes to trash. Diverged copies are
# reported and left alone.
deduped=0
while IFS= read -r dup_name; do
    ranked=$(
        while IFS= read -r f; do
            live=0
            is_live_project_dir "$(basename "$(dirname "$f")")" && live=1
            printf '%s %s %s %s\n' "$live" "$(stat -c %s "$f")" "$(stat -c %Y "$f")" "$f"
        done < <(find "$PROJECTS_DIR" -mindepth 2 -maxdepth 2 -type f -name "$dup_name") \
        | sort -k1,1nr -k2,2nr -k3,3nr
    )
    keeper=$(printf '%s\n' "$ranked" | head -1 | cut -d' ' -f4-)
    keeper_dir=$(basename "$(dirname "$keeper")")
    # Compare each copy against ALL kept ones, not only the keeper: two identical old copies that both
    # diverge from the keeper still contain each other.
    kept_files=("$keeper")
    while IFS= read -r line; do
        other=$(printf '%s' "$line" | cut -d' ' -f4-)
        other_size=$(printf '%s' "$line" | cut -d' ' -f2)
        container=""
        for k in "${kept_files[@]}"; do
            # A copy is redundant when its full content is a byte prefix of a kept copy.
            if cmp -s -n "$other_size" "$other" "$k"; then container=$k; break; fi
        done
        if [ -n "$container" ]; then
            container_dir=$(basename "$(dirname "$container")")
            if [ "$DRY_RUN" = 1 ]; then
                log "DRYRUN would trash duplicate $(basename "$(dirname "$other")")/$dup_name (contained in $container_dir)"
            elif trash_session "$other" "duplicate, contained in $container_dir"; then
                deduped=$((deduped + 1))
            fi
        else
            size_mb=$((other_size / 1048576))
            last=$(date -d "@$(last_activity_epoch "$other")" +%Y-%m-%d)
            info="\"$(session_title "$other")\", ${size_mb}MB, last activity $last"
            fork=$(fork_point "$other" "$keeper")
            [ -n "$fork" ] && info="$info, forked from $keeper_dir copy after $fork"
            log "kept diverged copy $(basename "$(dirname "$other")")/$dup_name ($info - review manually)"
            kept_files+=("$other")
        fi
    done < <(printf '%s\n' "$ranked" | tail -n +2)
done < <(find "$PROJECTS_DIR" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' -printf '%f\n' | sort | uniq -d)

# --- Phase 1b: sessions sharing (or containing) a custom title ---------------------------------------
# /rename titles live as "custom-title" entries inside the transcript and survive forks and bridge
# continuations, so different session files can show the same name in the resume picker. For every
# pair whose titles are equal or literal substrings of each other, a merge is attempted: with the own
# sessionId neutralized (every entry embeds it, so raw bytes can never match across files), an exact
# prefix overlap proves one file carries nothing beyond the other and it goes to trash. Pairs without
# exact overlap are genuinely different conversations - those are only reported for a manual rename
# or trash decision.
for project_dir in "$PROJECTS_DIR"/*/; do
    [ -d "$project_dir" ] || continue
    project_name=$(basename "$project_dir")
    titled_files=(); titled_titles=()
    for transcript in "$project_dir"*.jsonl; do
        [ -f "$transcript" ] || continue
        # The last entry wins: a session can be renamed multiple times.
        line=$(grep '"type"[[:space:]]*:[[:space:]]*"custom-title"' "$transcript" | tail -1) || true
        [ -n "$line" ] || continue
        title=$(printf '%s' "$line" | sed -nE 's/.*"customTitle"[[:space:]]*:[[:space:]]*"((\\.|[^"\\])*)".*/\1/p')
        [ -n "$title" ] || continue
        titled_files+=("$transcript"); titled_titles+=("$title")
    done
    declare -A gone=()
    for ((i = 0; i < ${#titled_files[@]}; i++)); do
        for ((j = i + 1; j < ${#titled_files[@]}; j++)); do
            [ -z "${gone[$i]:-}" ] && [ -z "${gone[$j]:-}" ] || continue
            ti=${titled_titles[$i]}; tj=${titled_titles[$j]}
            rel=0
            [ "$ti" = "$tj" ] && rel=1
            case "$ti" in *"$tj"*) rel=1 ;; esac
            case "$tj" in *"$ti"*) rel=1 ;; esac
            [ "$rel" = 1 ] || continue
            if [ "$(stat -c %s "${titled_files[$i]}")" -le "$(stat -c %s "${titled_files[$j]}")" ]; then
                si=$i; bi=$j
            else
                si=$j; bi=$i
            fi
            small=${titled_files[$si]}; big=${titled_files[$bi]}
            tmp_s=$(mktemp); tmp_b=$(mktemp)
            sed "s/$(basename "$small" .jsonl)/SID/g" "$small" > "$tmp_s"
            sed "s/$(basename "$big" .jsonl)/SID/g" "$big" > "$tmp_b"
            overlap=0
            cmp -s -n "$(stat -c %s "$tmp_s")" "$tmp_s" "$tmp_b" && overlap=1
            rm -f "$tmp_s" "$tmp_b"
            [ "$overlap" = 1 ] || continue
            big_id=$(basename "$big" .jsonl)
            label="titled \"${titled_titles[$si]}\", content prefix of ${big_id:0:8} \"${titled_titles[$bi]}\""
            if [ "$DRY_RUN" = 1 ]; then
                log "DRYRUN would trash duplicate $project_name/$(basename "$small") ($label)"
                gone[$si]=1
            elif trash_session "$small" "$label"; then
                deduped=$((deduped + 1))
                gone[$si]=1
            fi
        done
    done
    declare -A title_map=()
    for ((i = 0; i < ${#titled_files[@]}; i++)); do
        [ -z "${gone[$i]:-}" ] || continue
        title=${titled_titles[$i]}
        title_map[$title]="${title_map[$title]:-}${titled_files[$i]}"$'\n'
    done
    for title in "${!title_map[@]}"; do
        count=$(printf '%s' "${title_map[$title]}" | grep -c .) || true
        [ "$count" -ge 2 ] || continue
        list=""
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            id=$(basename "$f" .jsonl)
            size_mb=$(( $(stat -c %s "$f") / 1048576 ))
            last=$(date -d "@$(last_activity_epoch "$f")" +%Y-%m-%d)
            list="${list:+$list, }${id:0:8} (${size_mb}MB, last $last)"
        done <<< "${title_map[$title]}"
        log "same title \"$title\" in $project_name: $list - no exact overlap, rename or trash manually"
    done
    unset title_map gone
done

# --- Phase 2: empty sessions -------------------------------------------------------------------------
cutoff=$((now - MIN_AGE_HOURS * 3600))
moved=0
for project_dir in "$PROJECTS_DIR"/*/; do
    [ -d "$project_dir" ] || continue
    project_name=$(basename "$project_dir")
    for transcript in "$project_dir"*.jsonl; do
        [ -f "$transcript" ] || continue
        session_id=$(basename "$transcript" .jsonl)
        sidecar="$project_dir$session_id"

        total_size=$(stat -c %s "$transcript")
        sidecar_last=""
        if [ -d "$sidecar" ]; then
            total_size=$((total_size + $(du -sb "$sidecar" | cut -f1)))
            sidecar_last=$(find "$sidecar" -type f -printf '%T@\n' | sort -n | tail -1 | cut -d. -f1)
        fi
        # Size check first: parsing timestamps out of every large transcript would dominate the runtime.
        [ "$total_size" -ge "$MAX_SIZE_BYTES" ] && continue

        last_activity=$(last_activity_epoch "$transcript")
        [ -n "$sidecar_last" ] && [ "$sidecar_last" -gt "$last_activity" ] && last_activity=$sidecar_last
        [ "$last_activity" -ge "$cutoff" ] && continue
        # A /rename title marks a session the user intends to keep - never auto-trash those.
        grep -q '"type"[[:space:]]*:[[:space:]]*"custom-title"' "$transcript" && continue

        size_kb=$((total_size / 1024))
        label="${size_kb}KB, last activity $(date -d "@$last_activity" +%Y-%m-%d)"
        if [ "$DRY_RUN" = 1 ]; then
            log "DRYRUN would trash $project_name/$(basename "$transcript") ($label)"
        elif trash_session "$transcript" "$label"; then
            moved=$((moved + 1))
        fi
    done
done

# --- Phase 3: purge trash batches past retention. Batch folders are named yyyy-MM-dd (trash date). ---
purge_cutoff=$(date -d "-$RETENTION_DAYS days" +%Y-%m-%d)
purged=0
for batch in "$TRASH_DIR"/*/; do
    [ -d "$batch" ] || continue
    name=$(basename "$batch")
    printf '%s' "$name" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || continue
    [ "$name" \< "$purge_cutoff" ] || continue
    if [ "$DRY_RUN" = 1 ]; then
        log "DRYRUN would purge trash batch $name"
        continue
    fi
    rm -rf "$batch"
    log "purged trash batch $name"
    purged=$((purged + 1))
done

log "done: $deduped duplicate(s) and $moved empty session(s) trashed, $purged batch(es) purged"

if [ "$DRY_RUN" != 1 ]; then
    printf '%s' "$log_lines" >> "$LOG_FILE"
    # Keep the log bounded.
    if [ "$(wc -l < "$LOG_FILE")" -gt 5000 ]; then
        tail -n 2000 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
fi
