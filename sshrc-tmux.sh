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

	# A socket left by a server that died (a crash or a hard reset of the host) makes every command that expects a
	# server fail with "no server running": remove it so that a new server starts.
	if [ -S "$TMUXDIR/tmuxserver" ] && ! command "$tmux_bin" -S "$TMUXDIR/tmuxserver" list-sessions >/dev/null 2>&1; then
		rm --force -- "$TMUXDIR/tmuxserver" || return 1
	fi

	# -f replaces the host's own tmux config, so sshrc_tmux.conf loads that itself
	local tmux_args=(-S "$TMUXDIR/tmuxserver")
	if [ -r "$TMUXDIR/.sshrc.d/sshrc_tmux.conf" ]; then
		tmux_args+=(-f "$TMUXDIR/.sshrc.d/sshrc_tmux.conf")
		# -f is read only when the server starts. Apply updated settings before
		# creating a session on a server retained from an earlier login.
		case "${1:-}" in
		'' | new | new-session)
			if [ -S "$TMUXDIR/tmuxserver" ]; then
				TMUX_WRAPPED=1 SSHHOME="$TMUXDIR" SHELL="$TMUXDIR/bashsshrc" \
					command "$tmux_bin" -S "$TMUXDIR/tmuxserver" source-file -q \
					"$TMUXDIR/.sshrc.d/sshrc_tmux.conf" || return 1
			fi
			;;
		esac
	fi

	# Mark that we've wrapped to avoid recursion; use the real tmux binary
	TMUX_WRAPPED=1 SSHHOME="$TMUXDIR" SHELL="$TMUXDIR/bashsshrc" \
		command "$tmux_bin" "${tmux_args[@]}" "$@"
}
