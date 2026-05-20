#!/usr/bin/env bash
# install-hooks.sh — install the AI-Toolbox git hooks into .git/hooks/.
#
# Writes a thin shim for pre-commit and post-commit, each delegating to the
# tracked hook in tools/githooks/. Run once per clone. Idempotent: re-running
# just rewrites the shims. Refuses to clobber a pre-existing foreign hook.

APP_VERSION='0.1.3'
set -u

repo=$(git rev-parse --show-toplevel 2>/dev/null) || {
    printf 'install-hooks: not inside a git repository\n' >&2
    exit 1
}

marker='AI-Toolbox versioning shim'
rc=0

for h in pre-commit post-commit; do
    src="tools/githooks/$h"
    if [ ! -f "$repo/$src" ]; then
        printf 'install-hooks: missing %s — skipped\n' "$src" >&2
        rc=1
        continue
    fi
    hook="$repo/.git/hooks/$h"
    if [ -e "$hook" ] && ! grep -q "$marker" "$hook" 2>/dev/null; then
        printf 'install-hooks: %s exists and is not ours — left untouched\n' "$hook" >&2
        rc=1
        continue
    fi
    mkdir -p "$repo/.git/hooks"
    cat > "$hook" <<EOF
#!/bin/sh
# $marker — delegates to the tracked hook. Managed by tools/install-hooks.sh;
# edit $src instead of this file.
exec "\$(git rev-parse --show-toplevel)/$src" "\$@"
EOF
    chmod +x "$hook"
    printf 'install-hooks: installed %s -> %s\n' "$hook" "$src"
done

exit "$rc"
