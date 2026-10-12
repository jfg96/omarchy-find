#!/bin/bash
# Runs bench/qml/shell.qml in an isolated, hidden Quickshell instance:
# its own HOME, XDG_RUNTIME_DIR and XDG_CACHE_HOME, so it shares no sockets,
# config or instance registry with the running shell. The overlay is never
# opened, so no surface is created and the keyboard is never grabbed.
#
# Usage: qml_driver.sh HOME ENGINE CASES_JSON REPEATS OUT_LOG
set -euo pipefail
home=$1 engine=$2 cases=$3 repeats=$4 out=$5
plugin=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/ofind-qml.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/cfg" "$work/run" "$work/cache"
chmod 700 "$work/run"
shell=${OMARCHY_PATH:-/usr/share/omarchy}/shell
ln -s "$shell/Commons" "$work/cfg/Commons"
ln -s "$shell/Ui" "$work/cfg/Ui"
ln -s "$shell/services" "$work/cfg/services"
ln -s "$plugin" "$work/cfg/plugin"
cp "$plugin/bench/qml/shell.qml" "$work/cfg/shell.qml"
wayland=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/${WAYLAND_DISPLAY:-wayland-1}
HOME=$home XDG_RUNTIME_DIR=$work/run XDG_CACHE_HOME=$work/cache WAYLAND_DISPLAY=$wayland \
  QT_QPA_PLATFORM=wayland DRIVER_ENGINE=$engine DRIVER_CASES=$cases DRIVER_REPEATS=$repeats \
  timeout 600 quickshell -p "$work/cfg" > "$out" 2>&1 || true
grep -o 'DRIVER .*' "$out" | sed 's/^DRIVER //' > "$out.jsonl"
