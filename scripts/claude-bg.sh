#!/usr/bin/env bash
# claude-bg.sh — run Claude Code as a persistent tmux background session,
# wired up for Telegram via the claude-plugins-official Telegram plugin.
#
# Usage:
#   claude-bg.sh            attach if running, otherwise start and attach
#   claude-bg.sh start      create a fresh detached session
#   claude-bg.sh resume     continue the most recent session (--continue)
#   claude-bg.sh restart    stop + resume (preserves prior conversation)
#   claude-bg.sh attach     enter the running tmux session
#   claude-bg.sh stop       kill the tmux session
#   claude-bg.sh status     print running / stopped
#
# Common alias: `alias clbg='/path/to/claude-bg.sh'`
# See docs/ARCHITECTURE.md for why each flag is here.

set -euo pipefail

SESSION="claude-bg"
CLAUDE_BIN="${HOME}/.claude/local/claude"
# WORK_DIR is intentionally a dedicated directory — NOT $HOME.
# Reason: ~/.claude/projects/-Users-<you>/ accumulates every Claude Code
# session ever launched from $HOME (easily 10+ sessions from many
# terminals/IDEs). `claude --continue` picks the most-recently-modified
# jsonl in that pool, which means bg can hijack a totally unrelated
# session if any other Claude session was active just before restart.
# Isolating cwd to ~/.claude-bg/ ensures the session pool only contains
# bg's own history. See docs/ARCHITECTURE.md for the full story.
WORK_DIR="${HOME}/.claude-bg"
# CRITICAL: without the --channels flag, Telegram messages reach the MCP
# server but Claude Code refuses to deliver them ("Channel notifications
# skipped" in the MCP log). See docs/TROUBLESHOOTING.md #1.
#
# --dangerously-skip-permissions: a detached tmux session has nobody to
# answer permission prompts, so the first un-allowlisted Bash call hangs
# the whole session forever. Auto-approval is the only workable option
# for bg mode. The real defense is the allowlist in access.json — only
# Telegram user IDs in allowFrom can send messages that reach Claude at
# all. See docs/SECURITY.md for the full threat model.
CLAUDE_ARGS="--channels plugin:telegram@claude-plugins-official --dangerously-skip-permissions"

cmd="${1:-attach-or-start}"

session_exists() {
  tmux has-session -t "$SESSION" 2>/dev/null
}

start_session() {
  if session_exists; then
    echo "[claude-bg] session '$SESSION' is already running."
    return 0
  fi
  echo "[claude-bg] starting fresh Claude session in tmux '$SESSION'..."
  mkdir -p "$WORK_DIR"
  tmux new-session -d -s "$SESSION" -c "$WORK_DIR" "$CLAUDE_BIN $CLAUDE_ARGS"
  echo "[claude-bg] started. Attach with: claude-bg.sh attach"
}

resume_session() {
  if session_exists; then
    echo "[claude-bg] session '$SESSION' is already running — stop it first."
    return 1
  fi
  echo "[claude-bg] resuming most recent Claude session (--continue)..."
  mkdir -p "$WORK_DIR"
  tmux new-session -d -s "$SESSION" -c "$WORK_DIR" "$CLAUDE_BIN --continue $CLAUDE_ARGS"
  echo "[claude-bg] resumed. Attach with: claude-bg.sh attach"
}

restart_session() {
  if session_exists; then
    echo "[claude-bg] stopping existing session..."
    tmux kill-session -t "$SESSION"
    sleep 1
  fi
  resume_session
}

attach_session() {
  if ! session_exists; then
    echo "[claude-bg] no session running. Start with: claude-bg.sh start (fresh) or resume (continue)"
    exit 1
  fi
  tmux attach -t "$SESSION"
}

stop_session() {
  if ! session_exists; then
    echo "[claude-bg] no session to stop."
    return 0
  fi
  tmux kill-session -t "$SESSION"
  echo "[claude-bg] session '$SESSION' killed."
}

status_session() {
  if session_exists; then
    echo "[claude-bg] running"
    tmux list-sessions | grep "$SESSION"
  else
    echo "[claude-bg] stopped"
  fi
}

case "$cmd" in
  start)            start_session ;;
  resume)           resume_session ;;
  restart)          restart_session ;;
  attach)           attach_session ;;
  stop)             stop_session ;;
  status)           status_session ;;
  attach-or-start)
    if ! session_exists; then
      start_session
    fi
    attach_session
    ;;
  *)
    echo "Usage: $0 [start|resume|restart|attach|stop|status]"
    exit 1
    ;;
esac
