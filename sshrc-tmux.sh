#!/usr/bin/env bash
# Source from .sshrc after linking this file into ~/.sshrc.d.

# Wrap tmux to always use sshrc files in a temp tmux dir
function tmuxrc() {
	# Prevent infinite recursion if tmux calls tmux
	if [ -n "${TMUX_WRAPPED:-}" ]; then
		command tmux "$@"
		return
	fi

	local tmux_bin
	if ! tmux_bin="$(type -P tmux)"; then
		printf 'tmux: command not found\n' >&2
		return 127
	fi

	# Keep a stable socket across logins, but never share it between accounts.
	local TMUXDIR="${SSHRC_TMUX_DIR:-${TMPDIR:-/tmp}/sshrctmuxserver-$UID}"
	: "${SSHHOME:=$HOME}"

	(
		umask 077
		mkdir --parents -- "$TMUXDIR"
	) || return 1
	if [ -L "$TMUXDIR" ] || [ ! -O "$TMUXDIR" ]; then
		printf 'sshrc: tmux directory must be owned by the current user and not be a symlink: %s\n' "$TMUXDIR" >&2
		return 1
	fi
	chmod 700 -- "$TMUXDIR" || return 1

	rm --recursive --force -- "$TMUXDIR/.sshrc.d" || return 1
	cp --recursive -- "$SSHHOME/.sshrc" "$SSHHOME/bashsshrc" "$SSHHOME/sshrc" "$SSHHOME/.sshrc.d" "$TMUXDIR" || return 1

	# -f replaces the host's own tmux config, so sshrc_tmux.conf loads that itself
	local tmux_args=(-S "$TMUXDIR/tmuxserver")
	if [ -r "$TMUXDIR/.sshrc.d/sshrc_tmux.conf" ]; then
		tmux_args+=(-f "$TMUXDIR/.sshrc.d/sshrc_tmux.conf")
	fi

	# Mark that we've wrapped to avoid recursion; use the real tmux binary
	TMUX_WRAPPED=1 SSHHOME="$TMUXDIR" SHELL="$TMUXDIR/bashsshrc" \
		command "$tmux_bin" "${tmux_args[@]}" "$@"
}
