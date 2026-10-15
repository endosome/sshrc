#!/usr/bin/env bash
# Tests for the argument parsing in sshrc. Run with: bash tests/test_sshrc_parse.sh

source "$(dirname "${BASH_SOURCE[0]}")/../sshrc"

failures=0

# Run sshrc_parse on the arguments after the first three, then compare what it
# collected with the expectations.
#   assert_parse DESCRIPTION EXPECTED_SSHARGS EXPECTED_DOMAIN [EXPECTED_CMDARG] -- ARGS...
# EXPECTED_SSHARGS is the ssh arguments joined with "|".
assert_parse() {
  local description=$1 expected_args=$2 expected_domain=$3 expected_cmd=$4
  shift 5  # also drops the "--" separator

  SSHARGS=() DOMAIN= CMDARG=
  sshrc_parse "$@"

  local actual_args
  actual_args=$(IFS='|'; echo "${SSHARGS[*]}")
  if [[ $actual_args == "$expected_args" && $DOMAIN == "$expected_domain" &&
        $CMDARG == "$expected_cmd" ]]; then
    echo "ok   - $description"
  else
    echo "FAIL - $description"
    echo "       args:   expected '$expected_args', got '$actual_args'"
    echo "       domain: expected '$expected_domain', got '$DOMAIN'"
    echo "       cmd:    expected '$expected_cmd', got '$CMDARG'"
    failures=$((failures + 1))
  fi
}

assert_parse "plain host"                   ""             host "" -- host
assert_parse "flag before host"             "-v"           host "" -- -v host
assert_parse "separate value"               "-p|22"        host "" -- -p 22 host
assert_parse "attached value"               "-p22"         host "" -- -p22 host
assert_parse "attached value with ="        "-oBatchMode=yes" host "" -- -oBatchMode=yes host
assert_parse "value with spaces"            "-o|ProxyCommand ssh -W %h:%p jump" host "" \
  -- -o "ProxyCommand ssh -W %h:%p jump" host
assert_parse "flags bundle"                 "-Nf"          host "" -- -Nf host
assert_parse "bundle ending in value letter" "-vp|22"      host "" -- -vp 22 host
assert_parse "bundle with attached value"   "-vp22"        host "" -- -vp22 host
assert_parse "flags after a value letter are its value" "-pv" host "" -- -pv host
assert_parse "several bundles"              "-vNp|22|-tt"  host "" -- -vNp 22 -tt host
assert_parse "newer options -B and -P"      "-B|eth0|-P|tag" host "" -- -B eth0 -P tag host
assert_parse "user@host"                    ""             user@host "" -- user@host
assert_parse "command"                      ""             host "ls -l;  exit" -- host ls -l
assert_parse "options then command"         "-vp|22"       host "uptime;  exit" -- -vp 22 host uptime
assert_parse "-- ends options"              "-p|22"        -weird "ls;  exit" -- -p 22 -- -weird ls

if ((failures)); then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
