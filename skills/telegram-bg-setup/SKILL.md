---
name: telegram-bg-setup
description: Guides the user through setting up Claude Code as a persistent Telegram-backed background assistant, using the container model from claude-telegram-kit. One bot per container, multiple containers supported, no stuck one-shot dialogs. Use when the user wants to run Claude unattended from Telegram, add a new bot/container to an existing setup, or diagnose why their existing setup is stuck.
---

# telegram-bg-setup

Set up Claude Code to listen on Telegram via the official plugin, using the
`clbg` container model so the session survives detached tmux, multiple
independent bots work, and no first-run dialog ever blocks.

## When to use this skill

Trigger on:
- "set up claude on telegram", "connect claude to telegram"
- "run claude in the background so I can message it"
- "clbg", "claude-bg", "tmux claude setup"
- "add another bot for a separate session"
- "my bg session is stuck / not responding"
- Equivalent phrases in other languages

## Before you start — environment sanity check

Run these and report missing pieces. Don't assume.

```bash
which claude                                  # Claude Code installed?
which bun                                     # plugin dep
which tmux                                    # bg runner dep
python3 --version                             # clbg is Python 3.9+
ls ~/.claude/plugins/cache/claude-plugins-official/telegram/ 2>/dev/null
ls ~/.claude.json 2>/dev/null                 # must exist (claude has been run once)
```

Install missing deps before proceeding:
- Bun: `curl -fsSL https://bun.sh/install | bash`
- tmux: `brew install tmux` (macOS) or distro package manager
- Claude Code: https://claude.com/claude-code

## Step 1 — install claude-telegram-kit

Check if it's already installed (`which clbg`). If not:

```bash
git clone https://github.com/intelli-bruce/claude-telegram-kit.git ~/claude-telegram-kit
ln -s ~/claude-telegram-kit/scripts/claude-bg.sh ~/.local/bin/clbg
chmod +x ~/.local/bin/clbg
```

Verify: `clbg --help` should print the subcommand list.

## Step 2 — install the Telegram plugin (once per machine)

If `~/.claude/plugins/cache/claude-plugins-official/telegram/` doesn't exist:

Tell the user to run these inside a Claude Code session:
```
/plugin install telegram@claude-plugins-official
/reload-plugins
```
Then `/quit`.

## Step 3 — apply the typing indicator patch (recommended, once per machine)

```bash
PLUGIN_DIR="$HOME/.claude/plugins/cache/claude-plugins-official/telegram/0.0.4"
if ! grep -q "LOCAL PATCH" "$PLUGIN_DIR/server.ts"; then
  cp "$PLUGIN_DIR/server.ts" "$PLUGIN_DIR/server.ts.orig"
  patch -d "$PLUGIN_DIR" -p1 < ~/claude-telegram-kit/patches/telegram-typing-indicator.patch
  echo "patched"
else
  echo "patch already applied"
fi
```

Warn the user that plugin upgrades will wipe this patch. Re-apply from
`server.ts.orig` after upgrades.

## Step 4 — create a container with `clbg new`

Pick a label (alphanumeric + underscore/dash). Ask the user if they don't
have one in mind. Suggest `main` for the first, `work`/`personal`/`test`
for subsequent.

```bash
clbg new <label> --notes "<short description>"
```

This does everything automatically:
1. Creates `~/.claude-bg/<label>/` (container's cwd)
2. Creates `~/.claude/channels/telegram-<label>/` with `.env` and `access.json`
3. Pre-injects trust fields into `~/.claude.json` — **this is the magic
   that stops all first-run dialogs from ambushing the detached session**
4. Registers the container in `~/.claude-bg/containers.json`

The command prints the next steps — follow them literally.

## Step 5 — create a Telegram bot

The user does this interactively. Give them exact instructions:

> Open [@BotFather](https://t.me/BotFather) in Telegram and send `/newbot`.
>
> It asks for:
> 1. A **name** (shown in chat headers, can contain spaces)
> 2. A **username** ending in `bot` (e.g. `my_assistant_bot`)
>
> It replies with a token that looks like `123456789:AAH...`. Paste it into
> the next command — don't share the whole token with me in chat, put it
> directly in the `clbg link` call.

## Step 6 — link the token

```bash
clbg link <label> <token>
```

This writes the token to the container's `.env` (0600 permissions) and
verifies it by calling Telegram's `getMe` — if that succeeds, the bot's
username is stored in `containers.json` for display in `clbg list`.

## Step 7 — bootstrap the allowlist (CRITICAL for security)

The container's `access.json` starts with an empty `allowFrom`, so the bot
will reject every message by default. You need to add the user's Telegram
user ID. The clean way:

```bash
# Temporarily switch to pairing mode
clbg exec <label> /telegram:access policy pairing
```

Then tell the user: "DM your new bot now. It'll reply with a 6-character
pairing code. Tell me the code."

Once they give you the code:
```bash
clbg exec <label> /telegram:access pair <code>
clbg exec <label> /telegram:access policy allowlist
```

Verify:
```bash
cat ~/.claude/channels/telegram-<label>/access.json
```
Expected: `dmPolicy: "allowlist"`, `allowFrom` has the user's Telegram ID.

**This is not optional.** The container runs with
`--dangerously-skip-permissions`, which means every shell command gets
auto-approved. The allowlist is the only thing stopping an unauthorized
Telegram user from running arbitrary code. See `docs/SECURITY.md`.

## Step 8 — start the background session

```bash
clbg start <label>
```

By default this attaches to the new tmux session so the user can see Claude
boot and confirm the "Listening for channel messages from: plugin:telegram@claude-plugins-official"
line. They detach with `Ctrl+B D`.

If you're scripting and don't want to attach, use `--bg`:
```bash
clbg start <label> --bg
```

## Step 9 — test

Ask the user to DM their bot. Tell them to look for:
1. 👀 reaction on their message (within a second or two)
2. "typing…" in the chat header, held until reply
3. The reply

If any are missing, hand off to `docs/TROUBLESHOOTING.md` — don't
improvise. Every failure mode you're likely to see is already documented.

## Common diagnostic one-liners

Report which containers exist and their status:
```bash
clbg list
```

Deep status for one container (last session id, cost, token usage,
sessions-index if available):
```bash
clbg status <label>
```

Is the bg session stuck? Check its tmux screen:
```bash
tmux capture-pane -t claude-bg-<label>:0 -p | tail -30
```

Did the plugin actually register with Claude Code? Check the MCP log for
`Channel notifications registered` (good) or `Channel notifications skipped`
(bad — flag was missing):
```bash
ls -t ~/Library/Caches/claude-cli-nodejs/-Users-*--claude-bg-<label>/mcp-logs-plugin-telegram-telegram/*.jsonl \
  | head -1 | xargs tail
```

Is the bun MCP server actually running and connected to Telegram?
```bash
pgrep -f "bun server.ts"
lsof -a -p $(pgrep -f 'bun server.ts' | head -1) -i | grep 149.154
```

## Reporting back

When done, report:
- Which containers exist (`clbg list` output, redact cost if sensitive)
- Whether the typing patch was applied
- Whether allowlist is populated (count only, not the IDs)
- The attach command for each container (`clbg attach <label>`)
- The restart command (`clbg restart <label>`)

Do NOT:
- Paste bot tokens into chat
- Paste `access.json` contents with real user IDs
- Kill existing tmux sessions without confirmation
- Modify `~/.claude.json` directly — use `clbg new` which does it safely
  with a backup
