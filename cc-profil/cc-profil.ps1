# =============================================================================
# DEPRECATED forwarding shim — cc-profil was relocated to
#   aiprofil\adapters\cc-profil.ps1
# This keeps existing $PROFILE wirings (which dot-source this old path) working
# after a `git pull`, without forcing a re-install on every machine. Re-run
# `toolbox install --what cc-profil` to wire the new path directly; this shim
# can be removed once all installs have been re-linked.
# =============================================================================
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) '..\aiprofil\adapters\cc-profil.ps1') @args
