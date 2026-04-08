---
name: telegram-bg-setup
description: Guides the user through setting up Claude Code as a persistent Telegram-backed background assistant via tmux. Use when the user wants to talk to Claude from Telegram, run Claude unattended, or set up multi-session multi-bot configurations. Walks through bot creation, plugin install, flags, folder trust, allowlist, typing patch, and first test.
---

# telegram-bg-setup

Set up Claude Code to listen on Telegram via the official plugin, running
persistently in a detached tmux session. This skill guides the user through
every step needed to get from "nothing" to "I can DM my bot and Claude
replies even when my terminal is closed".

## When to use this skill

Trigger this skill when the user says any of:
- "set up claude on telegram", "connect claude to telegram"
- "run claude in the background so I can message it"
- "clbg", "claude-bg", "tmux claude setup"
- "add another bot for a separate session"
- Equivalent phrases in other languages — the setup steps are
  language-agnostic.

## Before you start — check the environment

Run these quick checks and report what's present/missing. Don't assume.

1. `which claude` — Claude Code installed?
2. `which bun` — Bun installed? (required by the plugin)
3. `which tmux` — tmux installed?
4. `ls ~/.claude/plugins/cache/claude-plugins-official/telegram/ 2>/dev/null` —
   plugin already installed?
5. `ls ~/.claude/channels/telegram/.env 2>/dev/null` — token already configured?
6. `ls ~/.claude-bg/ 2>/dev/null` — bg working directory exists?
7. `tmux has-session -t claude-bg 2>/dev/null && echo exists` — bg session running?

Based on what's missing, figure out which steps below to run and which to skip.

## Prerequisites install (only if missing)

- **Bun**: `curl -fsSL https://bun.sh/install | bash`
- **tmux**: `brew install tmux` (macOS) or your distro's package manager
- **Claude Code**: https://claude.com/claude-code

## Step 1 — Create the Telegram bot

The user must do this interactively in Telegram. Give them exact instructions:

> Open [@BotFather](https://t.me/BotFather) in Telegram and send `/newbot`.
> It will ask for:
> 1. A **name** — shown in chat headers, can contain spaces
> 2. A **username** — must end in `bot` (e.g. `my_assistant_bot`)
>
> It will reply with a token that looks like `123456789:AAH...`. Copy the
> whole thing. Don't paste it to me — you'll paste it into Claude Code
> directly in the next step.

Wait for the user to confirm they have the token before proceeding.

## Step 2 — Install the plugin (skip if already installed)

Tell the user to run these inside a Claude Code session (not a shell):

```
/plugin install telegram@claude-plugins-official
/reload-plugins
```

## Step 3 — Configure the token

Still inside Claude Code:

```
/telegram:configure <the token from BotFather>
```

This writes `~/.claude/channels/telegram/.env` with mode 0600. Verify with:

```bash
ls -la ~/.claude/channels/telegram/.env
# should be -rw------- (owner-only)
```

If it's not 0600, fix it:
```bash
chmod 600 ~/.claude/channels/telegram/.env
```

## Step 4 — Set up access control (CRITICAL for security)

The bg session will run with `--dangerously-skip-permissions`, which means
the allowlist is the **only** thing stopping an unauthorized Telegram user
from executing arbitrary shell commands via the bot. Take this seriously.

Inside any Claude Code session:

```
/telegram:access policy allowlist
```

This changes `dmPolicy` from the default `pairing` to `allowlist`. Pairing
is disabled — only explicitly allowlisted Telegram user IDs can message the
bot.

**Add the user's own Telegram user ID:**

Option A — pairing (one-time, then disable pairing):
1. Temporarily set `dmPolicy` back to `pairing`:
   `/telegram:access policy pairing`
2. User DMs their bot — the bot replies with a 6-char code
3. User runs: `/telegram:access pair <code>`
4. Switch back to allowlist: `/telegram:access policy allowlist`

Option B — manual (if the user already knows their Telegram user ID):
`/telegram:access allow <user_id>`

Verify:
```bash
cat ~/.claude/channels/telegram/access.json
```
Expected: `dmPolicy` is `"allowlist"`, `allowFrom` contains the user's ID.

## Step 5 — Install the kit

Find out where the user cloned this repo (ask if unclear). From there:

```bash
# Create alias — adjust path to wherever the user cloned the kit
echo "alias clbg='$(realpath scripts/claude-bg.sh)'" >> ~/.zshrc
source ~/.zshrc   # or open a new terminal

# Create the dedicated working directory
mkdir -p ~/.claude-bg
```

The dedicated cwd is important — see `docs/ARCHITECTURE.md` for why.
Short version: `claude --continue` picks the most-recently-modified session
jsonl in the cwd's pool, and if that pool contains unrelated sessions from
other terminals, the bg session will hijack one of them.

## Step 6 — Apply the typing indicator patch (recommended, optional)

Without this patch, the Telegram "typing…" indicator disappears after ~5
seconds even when Claude is thinking for minutes. The patch refreshes the
indicator every 4.5s.

```bash
PLUGIN_DIR="$HOME/.claude/plugins/cache/claude-plugins-official/telegram/0.0.4"
cp "$PLUGIN_DIR/server.ts" "$PLUGIN_DIR/server.ts.orig"
patch -d "$PLUGIN_DIR" -p0 < patches/telegram-typing-indicator.patch

# Verify
grep -n "LOCAL PATCH" "$PLUGIN_DIR/server.ts"
# should show 3 matches
```

Warn the user: **plugin upgrades will wipe this patch**. They can reapply
from `server.ts.orig` after upgrades.

## Step 7 — First launch and folder trust

```bash
clbg start      # create the detached tmux session
clbg attach     # enter it
```

On first launch, Claude Code asks "Is this a project you created or one
you trust?" for `~/.claude-bg`. Press Enter on "Yes, I trust this folder".
Then wait a few seconds for the Telegram plugin to load (you'll see
`~/.claude-bg` in the status bar and the plugin should announce itself
in the banner).

**Detach cleanly:** `Ctrl+B` then `D`. The session keeps running.

## Step 8 — Test

Tell the user: "DM your bot anything — say 'hello'. You should see:
1. A 👀 reaction appear on your message within a second or two
2. A persistent 'typing…' indicator in the chat header
3. Claude's reply"

If any of those three things don't happen, hand off to the
troubleshooting guide (`docs/TROUBLESHOOTING.md`) — don't try to debug
from scratch, every failure we've seen is already documented there.

## Optional: second bot for a second session

If the user wants multiple independent Claude sessions all reachable from
Telegram, each session needs its own bot and state directory. Tell the
user to:

1. Create a second bot via BotFather
2. Run the helper:
   ```bash
   scripts/telegram-new-bot.sh work  # creates ~/.claude/channels/telegram-work/
   ```
3. Paste the new token into the new `.env` that the script created
4. Configure access for the new state dir (run Claude with
   `TELEGRAM_STATE_DIR=~/.claude/channels/telegram-work`, then use
   `/telegram:access` as in Step 4)
5. Launch a new bg session pointed at that state dir (see
   `docs/MULTI-BOT.md` for the tmux command)

Do **not** reuse the same bot token across two Claude Code sessions — the
Telegram Bot API only allows one `getUpdates` client per token, and the
two sessions will race each other. Symptoms: messages disappear, replies
come from the "wrong" Claude, ack reactions land but typing never
progresses.

## Common mid-setup failures to anticipate

- "Plugin installed but `clbg` session doesn't respond to Telegram messages"
  → Check the MCP logs:
  `ls -t ~/Library/Caches/claude-cli-nodejs/-Users-*--claude-bg/mcp-logs-plugin-telegram-telegram/*.jsonl | head -1 | xargs tail`
  Look for `Channel notifications skipped` — means the `--channels` flag
  wasn't applied. `clbg` should pass it automatically; if you see this,
  the user probably launched `claude` manually inside the tmux session
  instead of using the script.

- "`clbg` shows running but first Bash command hangs"
  → Missing `--dangerously-skip-permissions`. Same cause: wrong launcher.

- "Claude in bg replies with context from something I never talked about"
  → Session hijacking via `--continue` from a shared cwd. Check `clbg status`
  and `tmux capture-pane -t claude-bg:0 -p | grep '~/'` — the status bar
  should show `~/.claude-bg`, not `~`. If it shows `~`, the user edited the
  script or is running Claude directly.

## Reporting back

When done, report concisely:
- Which steps were already done vs newly executed
- Where the bot token lives (path, not the value)
- Allowlist contents (just count, not IDs)
- Whether the typing patch was applied
- The one command to reattach: `clbg attach`
- The one command to restart if something hangs: `clbg restart`
