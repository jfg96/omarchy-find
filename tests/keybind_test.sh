#!/bin/bash
# bin/omarchy-find setup-keybind / remove-keybind against a sandboxed
# bindings.lua: only the managed block and the lines earlier versions wrote
# are ever touched. Also install-cli, in a sandboxed home.
set -uo pipefail

source_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
passed=0
failed=0
check() {
  if "$@"; then passed=$((passed + 1)); else echo "FAILED (line ${BASH_LINENO[0]}): $*" >&2; failed=$((failed + 1)); fi
}

fails() { ! "$@"; }
sandboxes=()
trap 'rm -rf -- "${sandboxes[@]}"' EXIT

setup() {
  sandbox=$(mktemp -d)
  sandboxes+=("$sandbox")
  mkdir -p "$sandbox/home/.config/hypr" "$sandbox/stubs"
  bindings="$sandbox/home/.config/hypr/bindings.lua"
  # No reload, no desktop database, no real omarchy-shell.
  printf '#!/bin/sh\necho "$*" >> "%s"\n' "$sandbox/hyprctl.log" > "$sandbox/stubs/hyprctl"
  chmod +x "$sandbox/stubs/hyprctl"
}
run() { HOME="$sandbox/home" XDG_CONFIG_HOME="$sandbox/home/.config" PATH="$sandbox/stubs:$PATH" \
  "$source_dir/bin/omarchy-find" "$@" >/dev/null 2>"$sandbox/stderr"; }
lines() { grep -c -- "$1" "$bindings"; }

user_lines='-- My own notes about omarchy-find, keep me
o.bind("SUPER + F", "Find notes", "omarchy-find open {\"query\":\"notes\"}")
-- Omarchy Find tips: Alt+Enter opens the folder'

# Setup appends one block and keeps every other line.
setup
printf '%s\n' "$user_lines" > "$bindings"
cp "$bindings" "$sandbox/original"
check run setup-keybind
check grep -qxF 'o.bind("ALT + SPACE", "Find files & folders", "omarchy-shell shell toggle oma.find")' "$bindings"
check [ "$(lines '>>> oma.find shortcut')" = 1 ]
check grep -qxF -- '-- My own notes about omarchy-find, keep me' "$bindings"
check grep -qF 'Find notes' "$bindings"
check grep -qxF -- '-- Omarchy Find tips: Alt+Enter opens the folder' "$bindings"
check cmp -s "$sandbox/original" "$bindings.omarchy-find.bak"

# Setup again with another shortcut replaces the block, not adds one.
check run setup-keybind "SUPER + F"
check [ "$(lines '>>> oma.find shortcut')" = 1 ]
check grep -qF '"SUPER + F", "Find files & folders"' "$bindings"
check [ "$(lines 'ALT + SPACE')" = 0 ]
# The backup is the file before the first change, not the last one.
check cmp -s "$sandbox/original" "$bindings.omarchy-find.bak"

# The same setup twice leaves the file byte for byte.
cp "$bindings" "$sandbox/before"
check run setup-keybind "SUPER + F"
check cmp -s "$sandbox/before" "$bindings"

# Remove gives back exactly the user's lines.
check run remove-keybind
check cmp -s "$sandbox/original" "$bindings"
# Removing again changes nothing.
check run remove-keybind
check cmp -s "$sandbox/original" "$bindings"

# The two lines earlier versions appended are replaced by the block.
setup
printf '%s\n\n-- Omarchy Find file search overlay\no.bind("ALT + SPACE", "Find files & folders", "omarchy-shell shell toggle oma.find")\n' \
  "$user_lines" > "$bindings"
printf '%s\n' "$user_lines" > "$sandbox/original"
check run setup-keybind
check [ "$(lines 'Omarchy Find file search overlay')" = 0 ]
check [ "$(lines 'shell toggle oma.find')" = 1 ]
check run remove-keybind
check cmp -s "$sandbox/original" "$bindings"

# And the even older upstream ones.
setup
printf '%s\n-- Omarchy Find file search overlay\no.bind("ALT + SPACE", "Find files & folders", "omarchy-find")\no.bind("ALT + SPACE", "Find files & folders", "omarchy-shell shell toggle jesseburlamaque.omarchy-find")\n' \
  "$user_lines" > "$bindings"
check run remove-keybind
check [ "$(lines 'Find files & folders')" = 0 ]
check grep -qF 'Find notes' "$bindings"

# A symlinked bindings.lua stays a symlink; its target is what changes.
setup
mkdir -p "$sandbox/dotfiles"
printf '%s\n' "$user_lines" > "$sandbox/dotfiles/bindings.lua"
ln -s "$sandbox/dotfiles/bindings.lua" "$bindings"
check run setup-keybind
check [ -L "$bindings" ]
check grep -qF 'shell toggle oma.find' "$sandbox/dotfiles/bindings.lua"
check [ -e "$sandbox/dotfiles/bindings.lua.omarchy-find.bak" ]

# A begin marker without its end is refused, and the file left alone.
setup
printf '%s\n-- >>> oma.find shortcut (managed by omarchy-find, edits are replaced)\no.bind("ALT + SPACE", "x", "y")\n-- everything below must survive\n' \
  "$user_lines" > "$bindings"
cp "$bindings" "$sandbox/original"
check fails run setup-keybind
check grep -qF 'without' "$sandbox/stderr"
check cmp -s "$sandbox/original" "$bindings"
check [ ! -e "$bindings.omarchy-find.bak" ]
check [ -z "$(find "$sandbox/home/.config/hypr" -name 'bindings.lua.*')" ]

# A shortcut that is not plain keys never reaches the file.
setup
printf '%s\n' "$user_lines" > "$bindings"
cp "$bindings" "$sandbox/original"
check fails run setup-keybind 'ALT + SPACE", "x", "rm -rf ~'
check cmp -s "$sandbox/original" "$bindings"

# The file keeps its permissions.
setup
printf '%s\n' "$user_lines" > "$bindings"
chmod 600 "$bindings"
check run setup-keybind
check [ "$(stat -c %a "$bindings")" = 600 ]

# install-cli links the plugin's script, replacing a copy left by earlier
# versions, and the link run again still points at the plugin.
setup
mkdir -p "$sandbox/home/.local/bin"
printf '#!/bin/sh\necho stale copy\n' > "$sandbox/home/.local/bin/omarchy-find"
check run install-cli
link="$sandbox/home/.local/bin/omarchy-find"
check [ -L "$link" ]
check [ "$(readlink -f "$link")" = "$(readlink -f "$source_dir/bin/omarchy-find")" ]
check env HOME="$sandbox/home" PATH="$sandbox/stubs:$PATH" "$link" install-cli >/dev/null
check [ "$(readlink -f "$link")" = "$(readlink -f "$source_dir/bin/omarchy-find")" ]
check [ -f "$sandbox/home/.local/share/applications/omarchy-find.desktop" ]

echo "$passed keybind tests passed, $failed failed"
(( failed == 0 ))
