# Multi-Bot: Running Multiple Independent Sessions

The Telegram Bot API allows only one `getUpdates` long-poll consumer per
bot token at a time. If you want multiple Claude Code sessions all
reachable from Telegram simultaneously, each session must have its own bot.

The official plugin supports this via the `TELEGRAM_STATE_DIR` environment
variable — it's mentioned in one line of the upstream README but never
explained. This doc is the full walkthrough.

## The mental model

```
Session A (work)          Session B (personal)        Session C (test)
     │                           │                           │
     ▼                           ▼                           ▼
@work_assistant_bot      @personal_claude_bot       @claude_test_bot
(token A)                (token B)                  (token C)
     │                           │                           │
     ▼                           ▼                           ▼
~/.claude/channels/      ~/.claude/channels/         ~/.claude/channels/
  telegram-work/           telegram-personal/          telegram-test/
  ├── .env (token A)       ├── .env (token B)         ├── .env (token C)
  ├── access.json          ├── access.json            ├── access.json
  └── approved/            └── approved/              └── approved/
```

Three bots, three state dirs, three Claude Code sessions. Each session
talks to exactly one bot, each bot has exactly one session polling it.
No races.

## Step 1 — Create additional bots in BotFather

DM [@BotFather](https://t.me/BotFather) and repeat `/newbot` for each
session you want. You'll end up with a token per bot. Name them
distinctly so you can tell which chat window goes to which Claude session
(e.g. `@me_work_bot`, `@me_personal_bot`).

## Step 2 — Scaffold a state dir

Use the helper script:

```bash
scripts/telegram-new-bot.sh work
# Creates ~/.claude/channels/telegram-work/ with:
#   .env           (TELEGRAM_BOT_TOKEN= placeholder)
#   access.json    (dmPolicy: allowlist, allowFrom: [], ackReaction: 👀)
#   approved/      (empty dir for pairing ACKs)
```

Paste the token for the "work" bot into `.env`:

```bash
echo 'TELEGRAM_BOT_TOKEN=<paste work bot token here>' > ~/.claude/channels/telegram-work/.env
chmod 600 ~/.claude/channels/telegram-work/.env
```

Repeat for each additional bot (`telegram-personal`, `telegram-test`, etc.).

## Step 3 — Bootstrap access for the new state dir

The new `access.json` has an empty `allowFrom`, so the bot will reject
every incoming message. You need to add your Telegram user ID.

The cleanest way is to temporarily flip to pairing mode, DM the new bot
to get a pairing code, then flip back to allowlist:

```bash
# Start a short-lived Claude session pointed at the new state dir
TELEGRAM_STATE_DIR=~/.claude/channels/telegram-work \
  claude --channels plugin:telegram@claude-plugins-official
```

Inside that session:

```
/telegram:access policy pairing
```

Now DM the new bot from Telegram. It will reply with a 6-char code. Back
in the Claude session:

```
/telegram:access pair <code>
/telegram:access policy allowlist
```

Verify:

```bash
cat ~/.claude/channels/telegram-work/access.json
# dmPolicy should be "allowlist"
# allowFrom should contain your Telegram user ID
```

Exit that Claude session (`Ctrl+D` or `/quit`).

## Step 4 — Launch each session as its own tmux background runner

The included `clbg` script uses a hard-coded tmux session name
(`claude-bg`) and the default state dir, so you need a tiny wrapper per
bot to avoid collisions. The simplest form:

```bash
cat > ~/.local/bin/clbg-work <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export TELEGRAM_STATE_DIR="$HOME/.claude/channels/telegram-work"
SESSION=claude-bg-work
CLAUDE_BIN="$HOME/.claude/local/claude"
WORK_DIR="$HOME/.claude-bg-work"
CLAUDE_ARGS="--channels plugin:telegram@claude-plugins-official --dangerously-skip-permissions"
mkdir -p "$WORK_DIR"

case "${1:-attach-or-start}" in
  start)
    if tmux has-session -t "$SESSION" 2>/dev/null; then
      echo "already running"
    else
      tmux new-session -d -s "$SESSION" -c "$WORK_DIR" "$CLAUDE_BIN $CLAUDE_ARGS"
      echo "started"
    fi ;;
  attach)  tmux attach -t "$SESSION" ;;
  stop)    tmux kill-session -t "$SESSION" 2>/dev/null || true ;;
  restart)
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    sleep 1
    tmux new-session -d -s "$SESSION" -c "$WORK_DIR" "$CLAUDE_BIN --continue $CLAUDE_ARGS" ;;
  status)
    tmux has-session -t "$SESSION" 2>/dev/null && echo "running" || echo "stopped" ;;
  *) echo "usage: $0 [start|attach|stop|restart|status]"; exit 1 ;;
esac
EOF
chmod +x ~/.local/bin/clbg-work
```

Key differences from the stock `clbg`:
- `TELEGRAM_STATE_DIR` export tells the plugin to read `.env` and `access.json`
  from the work directory instead of the default
- `SESSION=claude-bg-work` — a distinct tmux session name per bot, so they
  don't collide
- `WORK_DIR="$HOME/.claude-bg-work"` — a distinct cwd per bot, so the
  `--continue` session pool is also isolated

Duplicate the script for each bot (`clbg-personal`, `clbg-test`, ...)
and adjust the paths.

## Step 5 — First launch for each

For each new runner, the first time you start it, Claude Code will ask
for folder trust on the new cwd. You have to attach once and press Enter.

```bash
clbg-work start
clbg-work attach
# "Yes, I trust this folder" → Enter
# Wait for plugin to load (watch for the status bar to show ~/.claude-bg-work)
# Ctrl+B D to detach
```

Repeat for each bot. Each session now has its own:
- Working directory (`~/.claude-bg-work`, `~/.claude-bg-personal`, ...)
- Session jsonl pool (`~/.claude/projects/-Users-<you>--claude-bg-work/`, ...)
- Telegram state (`~/.claude/channels/telegram-work/`, ...)
- tmux session (`claude-bg-work`, ...)
- Bot (`@me_work_bot`, ...)

## Step 6 — Verify no polling races

You should now see one bun child process per active session, each with
connections to Telegram's API:

```bash
ps aux | grep "bun server.ts" | grep -v grep
# expected: one line per running session

lsof -a -p <each pid> -i -P 2>/dev/null | grep "149.154"
# expected: each pid has its own ESTABLISHED connections, different from the others
```

If two sessions point at the same `TELEGRAM_STATE_DIR`, you're back to
the racing problem. Double-check by running:

```bash
ps eww $(pgrep -f "bun server.ts")
# look for TELEGRAM_STATE_DIR=... in the env dump
```

If any two processes have the same state dir, kill one and fix its
launcher.

## Gotchas

- **Do not share `~/.claude-bg/` across runners.** The whole point of
  per-session cwds is isolation. Use `~/.claude-bg-<label>/`.
- **Do not share access.json across bots.** Each bot has its own
  allowlist. A Telegram user ID that's allowed on the work bot is not
  automatically allowed on the personal bot.
- **Apply the typing patch once, globally.** The patch lives in the
  plugin's `server.ts`, which is shared across all sessions, so you only
  apply it once and every bg runner benefits.
- **Plugin updates invalidate the patch for everyone.** Keep
  `server.ts.orig` around and script the re-application if you upgrade
  frequently.
- **One bot, one laptop, one session at a time.** If you launch the same
  bot's runner on two machines (or in a tmux session and interactively in
  a terminal), they race — the per-state-dir isolation only prevents
  races *within* a machine when each session has its own state dir.

## When multi-bot is overkill

If you rarely need more than one concurrent Telegram channel, don't
bother. Run the stock `clbg` and accept that any other Claude session
with the plugin loaded will race against it. The single-bot setup is
much simpler and covers 90% of use cases — most people just want "my
Claude, reachable from my phone".

Multi-bot shines when:
- You want separate conversation histories for work and personal contexts
- You need to isolate test/experimental sessions from a production-ish one
- You're running a shared machine where different people need their own
  Claude
- You want to run Claude in a PR review context that shouldn't see your
  personal history
