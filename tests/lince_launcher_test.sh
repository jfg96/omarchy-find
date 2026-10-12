#!/bin/bash
# bin/lince-launcher, offline: curl and uname are stubbed, no network.
set -uo pipefail

source_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
passed=0
failed=0
check() {
  if "$@"; then passed=$((passed + 1)); else echo "FAILED (line ${BASH_LINENO[0]}): $*" >&2; failed=$((failed + 1)); fi
}

setup() {
  sandbox=$(mktemp -d)
  plugin="$sandbox/plugin"
  stubs="$sandbox/stubs"
  mkdir -p "$plugin/bin" "$stubs" "$sandbox/data"
  cp "$source_dir/bin/lince-launcher" "$plugin/bin/"
  served="$sandbox/lince-v9.9.9-x86_64-linux"
  printf '#!/bin/sh\necho "fake lince $*"\n' > "$served"
  size=$(stat -c %s "$served")
  sha=$(sha256sum "$served" | cut -d' ' -f1)
  metadata "$size" "$sha"
  cat > "$stubs/curl" <<'STUB'
#!/bin/bash
out=""; prev=""
for a in "$@"; do [[ $prev == --output ]] && out=$a; prev=$a; done
echo x >> "$CURL_LOG"
(( ${CURL_EXIT:-0} == 0 )) || exit "$CURL_EXIT"
cp "$SERVED" "$out"
STUB
  printf '#!/bin/sh\n[ "$1" = -m ] && echo "${FAKE_ARCH:-x86_64}" || echo Linux\n' > "$stubs/uname"
  chmod +x "$stubs/curl" "$stubs/uname"
  export SERVED="$served" CURL_LOG="$sandbox/curl.log"
  : > "$CURL_LOG"
}
metadata() {
  printf 'LINCE_TAG=v9.9.9\nLINCE_ASSET=lince-v9.9.9-x86_64-linux\nLINCE_SIZE=%s\nLINCE_SHA256=%s\nLINCE_SOURCE_SHA=%s\n' \
    "$1" "$2" "$(printf '0%.0s' {1..40})" > "$plugin/lince-release.env"
}
launch() { PATH="$stubs:$PATH" XDG_DATA_HOME="$sandbox/data" "$plugin/bin/lince-launcher" "$@"; }
cached="omarchy-find/lince/v9.9.9/lince-v9.9.9-x86_64-linux"

# Downloads once, verifies, caches privately, then runs the cached copy.
setup
out=$(launch serve --x 2>&1)
check test "$out" == "fake lince serve --x"
check test -x "$sandbox/data/$cached"
check test "$(stat -c %a "$sandbox/data/omarchy-find/lince/v9.9.9")" == 700
launch --version >/dev/null
check test "$(wc -l < "$CURL_LOG")" -eq 1
rm -rf "$sandbox"

# A wrong checksum or size installs nothing.
setup
metadata "$size" "$(printf 'a%.0s' {1..64})"
check bash -c '! "$@" >/dev/null 2>&1' _ launch --version
check test ! -e "$sandbox/data/$cached"
metadata $((size + 1)) "$sha"
check bash -c '! "$@" >/dev/null 2>&1' _ launch --version
check test ! -e "$sandbox/data/$cached"
rm -rf "$sandbox"

# A tampered cached copy is replaced by a verified download.
setup
launch --version >/dev/null
printf 'evil' > "$sandbox/data/$cached"
check test "$(launch --version)" == "fake lince --version"
check test "$(wc -l < "$CURL_LOG")" -eq 2
rm -rf "$sandbox"

# Network failures are retryable (exit 1); unusable platforms are not (127).
setup
CURL_EXIT=6 launch --version >/dev/null 2>&1; status=$?
check test "$status" -eq 1
FAKE_ARCH=aarch64 launch --version >/dev/null 2>&1; status=$?
check test "$status" -eq 127
echo "LINCE_EXTRA=1" >> "$plugin/lince-release.env"
launch --version >/dev/null 2>&1; status=$?
check test "$status" -eq 127
rm -rf "$sandbox"

# A developer build at bin/lince overrides the release, without downloading.
setup
printf '#!/bin/sh\necho dev build\n' > "$plugin/bin/lince"
chmod +x "$plugin/bin/lince"
check test "$(launch --version)" == "dev build"
check test "$(wc -l < "$CURL_LOG")" -eq 0
rm -rf "$sandbox"

echo "$passed lince launcher tests passed, $failed failed"
(( failed == 0 ))
