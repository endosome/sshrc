#!/usr/bin/env bash
# Tests for moshrc, using a stub "mosh" that runs the remote command locally.
# Run with: bash tests/test_moshrc.sh

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

# check DESCRIPTION COMMAND...: passes if the command succeeds
check() {
  local description=$1
  shift
  if "$@"; then echo "ok   - $description"; else echo "FAIL - $description"; failures=$((failures + 1)); fi
}

exit_status_is() { (($1 == $2)); }
file_contains() { grep -q "$1" "$2"; }
dir_is_empty() { [[ -z $(ls -A "$1") ]]; }

# Stub mosh: drop everything up to and including "-- /bin/bash -c", then run
# the command locally in place of the server.
mkdir "$work/bin" "$work/home" "$work/tmp"
cat > "$work/bin/mosh" <<'STUB'
#!/bin/sh
while [ "$1" != -- ]; do shift; done
shift 3
exec /bin/bash -c "$1"
STUB
chmod +x "$work/bin/mosh"
export PATH="$work/bin:$PATH" HOME="$work/home" TMPDIR="$work/tmp"

# 1. Missing ~/.sshrc is an error and mosh is never reached
SSHHOME="$work/empty" bash "$repo/moshrc" host 2>/dev/null
check "missing .sshrc fails" exit_status_is $? 1

# 2. Oversized payload is rejected locally
mkdir -p "$work/big/.sshrc.d"
echo true > "$work/big/.sshrc"
head -c 100000 /dev/urandom > "$work/big/.sshrc.d/blob"
SSHHOME="$work/big" bash "$repo/moshrc" host 2>"$work/err"
check "oversized payload fails" exit_status_is $? 1
check "oversized payload explains why" file_contains 'too large' "$work/err"

# 3. Files arrive, .sshrc is sourced, and the temp dir is cleaned up. The
# final "bash --rcfile" needs a terminal, so this needs script(1).
if command -v script >/dev/null; then
  mkdir -p "$work/ok/.sshrc.d"
  echo 'FROMRC=yes' > "$work/ok/.sshrc"
  echo cfg > "$work/ok/.sshrc.d/conf"
  # shellcheck disable=SC2016  # expanded by the shell under test, not here
  echo 'echo "rc=$FROMRC conf=$(cat $SSHHOME/.sshrc.d/conf)"; exit' |
    SSHHOME="$work/ok" timeout 30 script -qec "bash $repo/moshrc host" /dev/null > "$work/out"
  check "files delivered and .sshrc sourced" file_contains 'rc=yes conf=cfg' "$work/out"
  check "server temp dir removed" dir_is_empty "$work/tmp"
else
  echo "skip - script(1) not available, skipping end-to-end test"
fi

if ((failures)); then echo "$failures test(s) failed"; exit 1; fi
echo "all tests passed"
