#!/usr/bin/env bash
# telegram-new-bot.sh — scaffold a new Telegram bot state directory for
# running multiple independent Claude Code sessions against separate bots.
#
# Each invocation creates ~/.claude/channels/telegram-<label>/ with an
# empty .env and a starter access.json. You then fill in the token and
# launch Claude with TELEGRAM_STATE_DIR pointed at the new directory.
#
# Usage:
#   telegram-new-bot.sh <label>
#
# Example:
#   telegram-new-bot.sh work
#   # → ~/.claude/channels/telegram-work/
#   # Next: echo 'TELEGRAM_BOT_TOKEN=<your new bot token>' > ~/.claude/channels/telegram-work/.env
#   # Then: TELEGRAM_STATE_DIR=~/.claude/channels/telegram-work clbg start
#
# See docs/MULTI-BOT.md for the full multi-bot setup walkthrough.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <label>" >&2
  echo "  label — short identifier for the new bot (e.g. work, personal, test)" >&2
  exit 1
fi

LABEL="$1"

# Basic sanitization — label becomes part of a directory name, so refuse
# anything with slashes or whitespace.
if ! [[ "$LABEL" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "Error: label must be alphanumeric/underscore/dash only (got: $LABEL)" >&2
  exit 1
fi

STATE_DIR="${HOME}/.claude/channels/telegram-${LABEL}"

if [[ -e "$STATE_DIR" ]]; then
  echo "Error: $STATE_DIR already exists — not overwriting." >&2
  echo "If you want to recreate it, remove it manually first." >&2
  exit 1
fi

mkdir -p "$STATE_DIR/approved"
chmod 700 "$STATE_DIR"

# Empty .env placeholder — user fills in the token
cat > "$STATE_DIR/.env" <<'EOF'
# Paste the token from BotFather on the next line (no quotes, no spaces)
TELEGRAM_BOT_TOKEN=
EOF
chmod 600 "$STATE_DIR/.env"

# Starter access.json — locked down by default.
# The user must add their Telegram user ID to allowFrom before the bot
# will respond to anything. Pairing is disabled — flip dmPolicy to
# "pairing" temporarily if you want to bootstrap via the pairing flow.
cat > "$STATE_DIR/access.json" <<'EOF'
{
  "dmPolicy": "allowlist",
  "allowFrom": [],
  "groups": {},
  "pending": {},
  "ackReaction": "👀"
}
EOF
chmod 600 "$STATE_DIR/access.json"

echo "Created: $STATE_DIR"
echo ""
echo "Next steps:"
echo "  1. Create a new bot with @BotFather on Telegram (send /newbot)"
echo "  2. Paste the token into: $STATE_DIR/.env"
echo "  3. Launch a Claude Code session pointed at this state dir to add"
echo "     your Telegram user ID to allowFrom:"
echo ""
echo "       TELEGRAM_STATE_DIR=$STATE_DIR \\"
echo "         claude --channels plugin:telegram@claude-plugins-official"
echo ""
echo "     Then inside Claude:"
echo "       /telegram:access policy pairing   # temporarily"
echo "       # DM your new bot → get pairing code"
echo "       /telegram:access pair <code>"
echo "       /telegram:access policy allowlist  # lock it back down"
echo ""
echo "  4. To run this as a background tmux session, see docs/MULTI-BOT.md"
echo "     (clbg doesn't know about state dirs by default — you launch"
echo "     it with TELEGRAM_STATE_DIR and a different tmux session name)."
