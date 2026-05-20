#!/usr/bin/env bash
# install-hooks.sh — install the AI-Toolbox git hooks into .git/hooks/.
#
# Writes a thin shim to .git/hooks/pre-commit that delegates to the tracked
# hook in tools/githooks/. Run once per clone. Idempotent: re-running just
# rewrites the shim. Refuses to clobber a pre-existing foreign pre-commit hook.

APP_VERSION='0.0.2'
set -u

repo=$(git rev-parse --show-toplevel 2>/dev/null) || {
    printf 'install-hooks: not inside a git repository\n' >&2
    exit 1
}

src='tools/githooks/pre-commit'
[ -f "$repo/$src" ] || {
    printf 'install-hooks: missing %s\n' "$src" >&2
    exit 1
}

hook="$repo/.git/hooks/pre-commit"
marker='AI-Toolbox versioning shim'
if [ -e "$hook" ] && ! grep -q "$marker" "$hook" 2>/dev/null; then
    printf 'install-hooks: %s exists and is not ours — left untouched\n' "$hook" >&2
    exit 1
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
