#!/usr/bin/env bash
# =============================================================================
# DEPRECATED forwarding shim — cc-profil was relocated to
#   aiprofil/adapters/cc-profil.sh
# This 1-liner keeps existing ~/.bashrc wirings (which point at this old path)
# working after a `git pull`, without forcing a re-install on every machine.
# Re-run `toolbox install --what cc-profil` to wire the new path directly;
# this shim can be removed once all installs have been re-linked.
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../aiprofil/adapters/cc-profil.sh" "$@"
