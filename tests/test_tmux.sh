#!/usr/bin/env bash
# Scripts passed to run_remote expand in the simulated remote shell.
# shellcheck disable=SC2016
set -Eeuo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp --directory)"
trap 'rm --recursive --force -- "$test_dir"' EXIT
test_home="$test_dir/home"
session="$test_dir/session"
tmux_dir="$test_dir/retained"
mock_bin="$test_dir/bin"
no_tmux_bin="$test_dir/no-tmux-bin"
mkdir --parents "$test_home" "$session/.sshrc.d" "$mock_bin" "$no_tmux_bin"

# What sshrc ships to the server: the rc file, its helpers and the aliases.
cat >"$session/.sshrc" <<'EOF'
source "$SSHHOME/.sshrc.d/sshrc-tmux.sh"
function tmux() { tmuxrc "$@"; }
SHELL="$(command -v bash)"
export SHELL
EOF
cp "$repo_dir/sshrc-tmux.sh" "$session/.sshrc.d/sshrc-tmux.sh"
printf '#!/usr/bin/env bash\n' >"$session/bashsshrc"
printf '#!/usr/bin/env bash\n' >"$session/sshrc"
printf "alias gp='git pull'\n" >"$session/.sshrc.d/aliases"
printf '# optional tmux config\n' >"$session/.sshrc.d/sshrc_tmux.conf"

# The only tools sourcing sshrc and running tmuxrc need.
for name in bash env ln cp rm mkdir chmod; do
	ln --symbolic "$(command -v "$name")" "$mock_bin/$name"
	ln --symbolic "$(command -v "$name")" "$no_tmux_bin/$name"
done

# Not at /usr/bin/tmux: the wrapper must find tmux through PATH.
cat >"$mock_bin/tmux" <<'EOF'
#!/usr/bin/env bash
{
	printf 'args=%s\n' "$*"
	printf 'SHELL=%s\n' "${SHELL:-}"
	printf 'SSHHOME=%s\n' "${SSHHOME:-}"
	printf 'TMUX_WRAPPED=%s\n' "${TMUX_WRAPPED:-}"
} >>"$MOCK_TMUX_LOG"
EOF
chmod +x "$mock_bin/tmux"

export MOCK_REPO="$repo_dir" MOCK_TMUX_LOG="$test_dir/tmux.log"
export MOCK_TMUX_DIR="$tmux_dir"

# Runs $1 in a simulated remote shell that sourced the session's .sshrc.
# $2 is the PATH; the default has the mock tmux.
function run_remote() {
	HOME="$test_home" SSHHOME="$session" PATH="${2:-$mock_bin}" SSHRC_TMUX_DIR="$tmux_dir" \
		env --unset=TMUX_WRAPPED bash --noprofile --norc -c \
		'set -Eeuo pipefail; source "$SSHHOME/.sshrc"; source /dev/stdin' <<<"$1"
}

function fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

function expect_log() {
	local expected="$1" message="$2"
	[[ "$(cat "$MOCK_TMUX_LOG")" == "$expected" ]] ||
		fail "$message. Got:"$'\n'"$(cat "$MOCK_TMUX_LOG")"
	: >"$MOCK_TMUX_LOG"
}

wrapped_log="args=-S $tmux_dir/tmuxserver -f $tmux_dir/.sshrc.d/sshrc_tmux.conf new-session -d -s work
SHELL=$tmux_dir/bashsshrc
SSHHOME=$tmux_dir
TMUX_WRAPPED=1"

# Plain `tmux` goes through the wrapper, like `tmuxrc`, and the retained copy
# of the session files exists for panes that outlive this login.
: >"$MOCK_TMUX_LOG"
run_remote '
[[ $(type -t tmux) == function ]] || { echo "tmux is not a function after sourcing sshrc" >&2; exit 1; }
[[ $(type -t tmuxrc) == function ]] || { echo "tmuxrc is not a function after sourcing sshrc" >&2; exit 1; }
tmux new-session -d -s work
'
expect_log "$wrapped_log" 'Plain tmux did not use the sshrc wrapper'
for retained in .sshrc bashsshrc sshrc .sshrc.d/aliases .sshrc.d/sshrc_tmux.conf .sshrc.d/sshrc-tmux.sh; do
	[[ -e $tmux_dir/$retained ]] || fail "Missing retained copy of $retained"
done
grep --quiet --fixed-strings -- "alias gp=" "$tmux_dir/.sshrc.d/aliases"

run_remote 'tmuxrc new-session -d -s work'
expect_log "$wrapped_log" 'tmuxrc stopped using the sshrc wrapper'

# The default is private to the remote UID and stable across separate logins.
# TMPDIR isolates this test from the real /tmp and any existing tmux servers.
default_tmux_dir="$test_dir/sshrctmuxserver-$UID"
mkdir --parents "$test_dir/sshrctmuxserver"
printf 'other user\n' >"$test_dir/sshrctmuxserver/marker"
for login in first second; do
	HOME="$test_home" SSHHOME="$session" PATH="$mock_bin" TMPDIR="$test_dir" \
		env --unset=TMUX_WRAPPED --unset=SSHRC_TMUX_DIR bash --noprofile --norc -c \
		'set -Eeuo pipefail; source "$SSHHOME/.sshrc"; tmux ls'
	expect_log "args=-S $default_tmux_dir/tmuxserver -f $default_tmux_dir/.sshrc.d/sshrc_tmux.conf ls
SHELL=$default_tmux_dir/bashsshrc
SSHHOME=$default_tmux_dir
TMUX_WRAPPED=1" "The $login login did not use the UID-specific directory"
done
[[ $(stat --format=%a "$default_tmux_dir") == 700 ]] || fail 'The default tmux directory is not private'
[[ $(cat "$test_dir/sshrctmuxserver/marker") == 'other user' ]] || fail 'The old shared directory was modified'

# Preparation failures must stop before tmux runs, even without shell errexit.
function expect_preparation_failure() {
	local directory="$1"
	HOME="$test_home" SSHHOME="$session" PATH="$mock_bin" SSHRC_TMUX_DIR="$directory" \
		env --unset=TMUX_WRAPPED bash --noprofile --norc -c \
		'source "$SSHHOME/.sshrc"; if tmux ls; then exit 1; fi' 2>"$test_dir/error" ||
		fail 'tmux reported success after a preparation failure'
	[[ -s $test_dir/error ]] || fail 'Preparation failed without a diagnostic'
	[[ ! -s $MOCK_TMUX_LOG ]] || fail 'tmux ran after a preparation failure'
}

ln --symbolic "$tmux_dir" "$test_dir/symlink"
expect_preparation_failure "$test_dir/symlink"
printf 'keep\n' >"$test_dir/file"
expect_preparation_failure "$test_dir/file"
[[ $(cat "$test_dir/file") == keep ]] || fail 'An existing file was deleted'
mv "$session/bashsshrc" "$test_dir/bashsshrc.away"
expect_preparation_failure "$tmux_dir"
mv "$test_dir/bashsshrc.away" "$session/bashsshrc"

# Inside a wrapped server (TMUX_WRAPPED inherited by panes) tmux is called as is.
HOME="$test_home" SSHHOME="$session" PATH="$mock_bin" SSHRC_TMUX_DIR="$tmux_dir" TMUX_WRAPPED=1 \
	bash --noprofile --norc -c 'set -Eeuo pipefail; source "$SSHHOME/.sshrc"; tmux list-panes'
expect_log 'args=list-panes
SHELL='"$mock_bin"'/bash
SSHHOME='"$session"'
TMUX_WRAPPED=1' 'tmux inside a wrapped pane did not pass through unchanged'

# `command tmux` is the way to the host's own tmux server and socket.
run_remote 'command tmux ls'
expect_log 'args=ls
SHELL='"$mock_bin"'/bash
SSHHOME='"$session"'
TMUX_WRAPPED=' '`command tmux` did not bypass the wrapper'

# A payload without sshrc_tmux.conf (stale links) still starts tmux, with the
# host's own configuration.
mv "$session/.sshrc.d/sshrc_tmux.conf" "$test_dir/sshrc_tmux.conf.away"
run_remote 'tmux new-session -d -s work'
expect_log "args=-S $tmux_dir/tmuxserver new-session -d -s work
SHELL=$tmux_dir/bashsshrc
SSHHOME=$tmux_dir
TMUX_WRAPPED=1" 'tmux was given -f although no sshrc_tmux.conf was shipped'
mv "$test_dir/sshrc_tmux.conf.away" "$session/.sshrc.d/sshrc_tmux.conf"

# Without tmux the wrapper reports it like the shell would, instead of failing
# on a missing /usr/bin/tmux.
status=0
run_remote 'tmux ls' "$no_tmux_bin" 2>"$test_dir/error" || status=$?
[[ $status -eq 127 ]] || fail "Expected exit 127 without tmux, got $status"
[[ "$(cat "$test_dir/error")" == 'tmux: command not found' ]] ||
	fail "Unexpected error without tmux: $(cat "$test_dir/error")"
[[ ! -s $MOCK_TMUX_LOG ]] || fail 'tmux ran although it is not installed.'

printf 'SSHRC tmux wrapper tests passed\n'
