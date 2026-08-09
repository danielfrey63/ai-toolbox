#!/usr/bin/env bash
# Moves "empty" Claude Code sessions (small transcripts) into a trash folder and purges trash entries
# past retention. Bash port of cleanup-sessions.ps1 — see that file for the full description.
# Desired-state and idempotent: re-runs only act on sessions that currently match the criteria.
set -euo pipefail

MAX_SIZE_BYTES=$((250 * 1024))
MIN_AGE_DAYS=3
RETENTION_DAYS=30
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --max-size-bytes) MAX_SIZE_BYTES=$2; shift 2 ;;
        --min-age-days)   MIN_AGE_DAYS=$2; shift 2 ;;
        --retention-days) RETENTION_DAYS=$2; shift 2 ;;
        --dry-run)        DRY_RUN=1; shift ;;
        *) echo "usage: cleanup-sessions.sh [--max-size-bytes N] [--min-age-days N] [--retention-days N] [--dry-run]" >&2; exit 2 ;;
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
cutoff=$((now - MIN_AGE_DAYS * 86400))
today_batch="$TRASH_DIR/$(date +%Y-%m-%d)"
moved=0

for project_dir in "$PROJECTS_DIR"/*/; do
    [ -d "$project_dir" ] || continue
    project_name=$(basename "$project_dir")
    for transcript in "$project_dir"*.jsonl; do
        [ -f "$transcript" ] || continue
        session_id=$(basename "$transcript" .jsonl)
        sidecar="$project_dir$session_id"

        total_size=$(stat -c %s "$transcript")
        last_activity=$(stat -c %Y "$transcript")
        if [ -d "$sidecar" ]; then
            total_size=$((total_size + $(du -sb "$sidecar" | cut -f1)))
            sidecar_last=$(find "$sidecar" -type f -printf '%T@\n' | sort -n | tail -1 | cut -d. -f1)
            [ -n "$sidecar_last" ] && [ "$sidecar_last" -gt "$last_activity" ] && last_activity=$sidecar_last
        fi

        [ "$total_size" -ge "$MAX_SIZE_BYTES" ] && continue
        [ "$last_activity" -ge "$cutoff" ] && continue

        size_kb=$((total_size / 1024))
        last_str=$(date -d "@$last_activity" +%Y-%m-%d)
        if [ "$DRY_RUN" = 1 ]; then
            log "DRYRUN would trash $project_name/$(basename "$transcript") (${size_kb}KB, last activity $last_str)"
            continue
        fi

        target="$today_batch/$project_name"
        mkdir -p "$target"
        if mv -f "$transcript" "$target/"; then
            if [ -d "$sidecar" ]; then
                rm -rf "$target/$session_id"
                mv -f "$sidecar" "$target/"
            fi
            log "trashed $project_name/$(basename "$transcript") (${size_kb}KB, last activity $last_str)"
            moved=$((moved + 1))
        else
            log "skipped $project_name/$(basename "$transcript"): move failed"
        fi
    done
done

# Purge trash batches past retention. Batch folders are named yyyy-MM-dd (their trash date).
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

log "done: $moved session(s) trashed, $purged batch(es) purged"

if [ "$DRY_RUN" != 1 ]; then
    printf '%s' "$log_lines" >> "$LOG_FILE"
    # Keep the log bounded.
    if [ "$(wc -l < "$LOG_FILE")" -gt 5000 ]; then
        tail -n 2000 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
fi
