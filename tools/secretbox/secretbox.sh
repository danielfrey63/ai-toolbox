#!/usr/bin/env bash
# =============================================================================
# secretbox — carry a repo's secrets inside the repo, encrypted.
#
# The problem: config that references secrets is versioned and transferable
# (agents in pmo/config/orgs.json, aiprofil profile names), but the secrets
# themselves (.env files with live keys) are gitignored and die with the
# machine. secretbox packs them into one age-encrypted bundle that IS tracked,
# so a fresh clone plus one passphrase restores a working setup offline.
#
# Files:
#   .secretbox    manifest at the repo root: one glob per line, relative to
#                 the root, comments with '#'. *.example files never match.
#   secrets.age   the encrypted bundle (tar.gz inside age), tracked in git.
#
# Commands (always run inside the target repo):
#   secretbox pack            collect manifest files -> encrypt -> secrets.age
#   secretbox unpack          restore missing files from the bundle
#   secretbox unpack --force  also overwrite files that differ locally
#   secretbox status          compare bundle against the working tree
#   secretbox ls              list bundle contents (asks for the passphrase)
#
# Security model, stated plainly:
#   - age -p uses scrypt for key derivation and an AEAD cipher; the bundle is
#     only as strong as the passphrase. Use a long one (diceware, 6+ words).
#   - git never forgets: every packed bundle stays readable in history with
#     the passphrase of THAT commit. Rotating a leaked key means revoking it
#     at the provider, not just repacking.
#   - pack refuses to run if a matched file is tracked in git — plaintext
#     secrets must never ride along unencrypted.
# =============================================================================

APP_VERSION='0.2.8'

set -euo pipefail

MANIFEST=".secretbox"
BUNDLE="secrets.age"

die() { printf 'secretbox: %s\n' "$*" >&2; exit 1; }

command -v age >/dev/null 2>&1 || die "age fehlt (Devbox: scoop install age · Ubuntu: apt install age)"

# Interactive by default (age asks at the TTY). With AGE_PASSPHRASE set and the
# batchpass plugin present, encryption/decryption run non-interactively — for
# tests and automation. Mind the shell history when setting it.
age_flags() {
    if [ -n "${AGE_PASSPHRASE:-}" ] && command -v age-plugin-batchpass >/dev/null 2>&1; then
        printf '%s' "-j batchpass"
    else
        printf '%s' "-p"
    fi
}
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || die "kein Git-Repo"
cd "$ROOT"
[ -f "$MANIFEST" ] || die "Manifest $MANIFEST fehlt im Repo-Root"

# --- manifest patterns (loaded once — matches() runs per file) ---------------
PATS=()
load_patterns() {
    local line
    while IFS= read -r line; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -n "$line" ] && PATS+=("$line")
    done < "$MANIFEST"
    [ "${#PATS[@]}" -gt 0 ] || die "Manifest $MANIFEST enthält keine Muster"
}
load_patterns

# True if $1 matches any manifest pattern ([[ == ]] fnmatch: * crosses /).
# Pure bash, no subprocess — this runs once per candidate file.
matches() {
    local f="$1" p
    case "$f" in *.example) return 1 ;; esac
    for p in "${PATS[@]}"; do
        # shellcheck disable=SC2053
        [[ "$f" == $p ]] && return 0
    done
    return 1
}

# Candidate secrets are by definition gitignored, so ask git for the ignored
# files instead of globbing the working tree — a ** walk through a large repo
# takes minutes, git's index answers instantly.
collect() {
    local f
    while IFS= read -r f; do
        matches "$f" && printf '%s\n' "$f"
    done < <(git ls-files --others --ignored --exclude-standard) | sort -u
}

# --- guards -------------------------------------------------------------------
assert_untracked() {
    # A manifest pattern that matches a TRACKED file means plaintext secrets
    # are already in git — packing would give false comfort. Hard stop.
    local f bad=0
    while IFS= read -r f; do
        if matches "$f"; then
            printf 'secretbox: %s ist in git getrackt — Klartext-Secret im Repo!\n' "$f" >&2
            bad=1
        fi
    done < <(git ls-files)
    [ "$bad" = 0 ] || die "abgebrochen (erst git rm --cached und Historie prüfen)"
}

cmd_pack() {
    local files tmp
    assert_untracked
    files=$(collect)
    [ -n "$files" ] || die "Manifest matcht keine Dateien — nichts zu packen"
    printf 'Packe %d Datei(en):\n' "$(printf '%s\n' "$files" | wc -l)"
    printf '  %s\n' $files
    tmp=$(mktemp)
    trap "rm -f '$tmp' '${BUNDLE}.new'" EXIT
    printf '%s\n' "$files" | tar -czf "$tmp" -T -
    # age asks for the passphrase twice on encrypt; write via temp for atomicity.
    # shellcheck disable=SC2046
    age $(age_flags) -e -o "${BUNDLE}.new" "$tmp"
    mv "${BUNDLE}.new" "$BUNDLE"
    printf '%s geschrieben (%s Bytes) — committen nicht vergessen.\n' "$BUNDLE" "$(wc -c < "$BUNDLE")"
}

# Decrypt the bundle into a temp dir; echoes the dir. Caller cleans up.
decrypt_to_tmp() {
    [ -f "$BUNDLE" ] || die "$BUNDLE fehlt — auf diesem Klon wurde nie gepackt/gepullt"
    local dir
    dir=$(mktemp -d)
    local dflags=""
    [ -n "${AGE_PASSPHRASE:-}" ] && command -v age-plugin-batchpass >/dev/null 2>&1 && dflags="-j batchpass"
    # shellcheck disable=SC2086
    age -d $dflags "$BUNDLE" | tar -xzf - -C "$dir" || { rm -rf "$dir"; die "Entschlüsselung fehlgeschlagen (Passwort?)"; }
    printf '%s\n' "$dir"
}

cmd_unpack() {
    local force="${1:-}" dir f created=0 skipped=0 differs=0
    dir=$(decrypt_to_tmp)
    trap "rm -rf '$dir'" EXIT
    while IFS= read -r f; do
        f="${f#./}"
        if [ ! -f "$f" ]; then
            mkdir -p "$(dirname "$f")"
            cp "$dir/$f" "$f"
            chmod 600 "$f"
            printf '[NEU]       %s\n' "$f"
            created=$((created + 1))
        elif cmp -s "$dir/$f" "$f"; then
            skipped=$((skipped + 1))
        elif [ "$force" = "--force" ]; then
            cp "$dir/$f" "$f"
            chmod 600 "$f"
            printf '[ERSETZT]   %s\n' "$f"
            created=$((created + 1))
        else
            printf '[WEICHT AB] %s  (lokal behalten — überschreiben mit: unpack --force)\n' "$f"
            differs=$((differs + 1))
        fi
    done < <(cd "$dir" && find . -type f | sort)
    printf '%d hergestellt, %d unverändert, %d abweichend.\n' "$created" "$skipped" "$differs"
}

cmd_status() {
    local files f in_bundle dir
    files=$(collect)
    if [ ! -f "$BUNDLE" ]; then
        printf 'Kein %s. Lokale Manifest-Treffer:\n' "$BUNDLE"
        printf '  %s\n' $files
        return
    fi
    dir=$(decrypt_to_tmp)
    trap "rm -rf '$dir'" EXIT
    in_bundle=$(cd "$dir" && find . -type f | sed 's|^\./||' | sort)
    for f in $(printf '%s\n%s\n' "$files" "$in_bundle" | sort -u); do
        if [ ! -f "$dir/$f" ]; then
            printf '[NUR LOKAL]  %s  (pack aktualisiert das Bundle)\n' "$f"
        elif [ ! -f "$f" ]; then
            printf '[NUR BUNDLE] %s  (unpack stellt her)\n' "$f"
        elif cmp -s "$dir/$f" "$f"; then
            printf '[OK]         %s\n' "$f"
        else
            printf '[WEICHT AB]  %s\n' "$f"
        fi
    done
}

cmd_ls() {
    local dir
    dir=$(decrypt_to_tmp)
    trap "rm -rf '$dir'" EXIT
    (cd "$dir" && find . -type f | sed 's|^\./||' | sort)
}

case "${1:-help}" in
    pack)   cmd_pack ;;
    unpack) cmd_unpack "${2:-}" ;;
    status) cmd_status ;;
    ls)     cmd_ls ;;
    *)      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
