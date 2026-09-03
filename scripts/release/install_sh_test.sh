#!/usr/bin/env bash
# Tests for the tarball installer's pure functions.
#
# Run: bash scripts/release/install_sh_test.sh
#
# The installer's job is to turn "error while loading shared libraries:
# libwebkit2gtk-4.1.so.0" into "sudo apt install libwebkit2gtk-4.1-0". These
# tests cover the mapping and the command construction, which is where that
# translation lives.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$SCRIPT_DIR/linux_tarball_extras/install.sh"
FAILURES=0

assert_eq() {
  if [ "$1" != "$2" ]; then
    echo "FAIL: $3"
    echo "  expected: $2"
    echo "  actual:   $1"
    FAILURES=$((FAILURES + 1))
  else
    echo "ok: $3"
  fi
}

# Sourcing with SUBMERSION_INSTALL_SH_TEST set defines the functions without
# running the installer.
SUBMERSION_INSTALL_SH_TEST=1
export SUBMERSION_INSTALL_SH_TEST
# shellcheck source=/dev/null
. "$INSTALLER"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
cat > "$WORKDIR/deps.json" <<'JSON'
{
  "_comment": "test fixture",
  "libgtk-3.so.0": {"apt": "libgtk-3-0", "rpm": "libgtk-3.so.0()(64bit)", "dnf": "gtk3", "pacman": "gtk3", "zypper": "libgtk-3-0"},
  "libwebkit2gtk-4.1.so.0": {"apt": "libwebkit2gtk-4.1-0", "rpm": "x", "dnf": "webkit2gtk4.1", "pacman": "webkit2gtk-4.1", "zypper": "libwebkit2gtk-4_1-0"}
}
JSON

assert_eq "$(map_soname "$WORKDIR/deps.json" "libgtk-3.so.0" apt)" \
  "libgtk-3-0" "maps a soname to its apt package"

assert_eq "$(map_soname "$WORKDIR/deps.json" "libgtk-3.so.0" pacman)" \
  "gtk3" "maps a soname to its pacman package"

assert_eq "$(map_soname "$WORKDIR/deps.json" "libunknown.so.9" apt)" \
  "" "returns empty for an unmapped soname rather than guessing"

assert_eq "$(install_command_for apt "libgtk-3-0 libwebkit2gtk-4.1-0")" \
  "sudo apt install libgtk-3-0 libwebkit2gtk-4.1-0" "builds the apt command"

assert_eq "$(install_command_for dnf "gtk3")" \
  "sudo dnf install gtk3" "builds the dnf command"

assert_eq "$(install_command_for pacman "gtk3")" \
  "sudo pacman -S --needed gtk3" "builds the pacman command"

assert_eq "$(install_command_for zypper "gtk3")" \
  "sudo zypper install gtk3" "builds the zypper command"

assert_eq "$(install_command_for unknown "gtk3")" \
  "" "returns empty for an unrecognized package manager"

# The preflight reads the column named after the detected package manager.
# The rpm column is deliberately not one of them: it holds soname provides
# like libgtk-3.so.0()(64bit), which fpm needs and a human cannot type.
assert_eq "$(map_soname "$WORKDIR/deps.json" "libgtk-3.so.0" dnf)" \
  "gtk3" "maps a soname to a human-readable dnf package name"

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES test(s) failed"
  exit 1
fi
echo "all tests passed"
