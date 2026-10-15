#!/usr/bin/env bash
# End-to-end tests of sshrc and moshrc against a real ssh server (and a real
# mosh-server), which needs a login that works without a prompt.
#
#   SSHRC_TEST_HOST=localhost SSHRC_TEST_KEY=~/.ssh/some_key \
#       bash tests/test_integration.sh
#
# Skips itself if SSHRC_TEST_HOST is unset. Sessions need a terminal, so they
# are run under script(1) with the shell commands fed in on stdin.

# Many strings below are meant to be expanded by the shell on the server (or
# in the session under test), not by this script.
# shellcheck disable=SC2016

if [[ -z $SSHRC_TEST_HOST ]]; then
  echo "skip - set SSHRC_TEST_HOST (and optionally SSHRC_TEST_KEY) to run"
  exit 0
fi

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

# Options that make ssh log in unattended with the test key
ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
if [[ -n $SSHRC_TEST_KEY ]]; then
  ssh_opts+=(-i "$SSHRC_TEST_KEY" -o IdentitiesOnly=yes)
fi

# check DESCRIPTION COMMAND...: passes if the command succeeds
check() {
  local description=$1
  shift
  if "$@"; then echo "ok   - $description"; else echo "FAIL - $description"; failures=$((failures + 1)); fi
}
file_contains() { grep -qF -- "$1" "$2"; }

# Files that sshrc sends: .sshrc sets FROMRC, .sshrc.d/conf is plain data
mkdir -p "$work/home/.sshrc.d"
echo 'FROMRC=yes' > "$work/home/.sshrc"
echo cfg > "$work/home/.sshrc.d/conf"

# Leftover sshrc directories in the server's /tmp (the server is the same
# machine only when testing against localhost; otherwise this is a no-op)
leftovers() { find /tmp -maxdepth 1 -name '.*.sshrc.????' 2>/dev/null | wc -l; }
leftovers_before=$(leftovers)

# run_session OUTFILE COMMAND...: run COMMAND on a terminal, feeding the
# shell commands in $session_input to it. The terminal needs a size, or the
# mosh client aborts.
run_session() {
  local out=$1
  shift
  printf '%s\n' "$session_input" |
    SSHHOME="$work/home" timeout 60 script -qec "stty rows 24 cols 80; $(printf '%q ' "$@")" /dev/null > "$out"
}

# 1. sshrc: interactive session sources .sshrc and gets .sshrc.d
session_input='echo "rc=$FROMRC conf=$(cat $SSHHOME/.sshrc.d/conf)"; exit'
run_session "$work/out1" bash "$repo/sshrc" "${ssh_opts[@]}" "$SSHRC_TEST_HOST"
check "sshrc: .sshrc sourced and .sshrc.d delivered" file_contains 'rc=yes conf=cfg' "$work/out1"

# 2. sshrc: a command argument arrives exactly as typed
# (two spaces inside double quotes, a variable, and a single-quoted $HOME)
command_arg="echo \"a  b\" \$FROMRC '\$HOME'"
run_session "$work/out2" bash "$repo/sshrc" "${ssh_opts[@]}" "$SSHRC_TEST_HOST" "$command_arg"
check "sshrc: command with quotes runs verbatim" file_contains 'a  b yes $HOME' "$work/out2"

# 3. sshrc: bundled option with a separate value (-q, -p 22) finds the host
session_input='echo bundle-ok; exit'
run_session "$work/out3" bash "$repo/sshrc" "${ssh_opts[@]}" -qp 22 "$SSHRC_TEST_HOST"
check "sshrc: bundled -qp 22 parsed" file_contains 'bundle-ok' "$work/out3"

# 4. sshrc: attached value form (-p22) and the "--" separator
run_session "$work/out4" bash "$repo/sshrc" "${ssh_opts[@]}" -p22 -- "$SSHRC_TEST_HOST"
check "sshrc: -p22 and -- parsed" file_contains 'bundle-ok' "$work/out4"

# 5. moshrc: same as test 1 over a real mosh session
if command -v mosh >/dev/null; then
  session_input='echo "rc=$FROMRC conf=$(cat $SSHHOME/.sshrc.d/conf)"; exit'
  run_session "$work/out5" bash "$repo/moshrc" --ssh="ssh ${ssh_opts[*]}" "$SSHRC_TEST_HOST"
  check "moshrc: .sshrc sourced and .sshrc.d delivered" file_contains 'rc=yes conf=cfg' "$work/out5"
else
  echo "skip - mosh not installed"
fi

# 6. Nothing left behind in the server's /tmp
sleep 1
check "no sshrc directories left in /tmp" test "$(leftovers)" -eq "$leftovers_before"

if ((failures)); then echo "$failures test(s) failed"; exit 1; fi
echo "all tests passed"
