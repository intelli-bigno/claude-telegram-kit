# Multi-Bot: Running Multiple Independent Sessions

Run N independent Claude Code sessions, each reachable from its own
Telegram bot, all on one machine. With `clbg`, this is one command per
container.

## Why separate bots instead of one bot with topics?

The Telegram Bot API allows exactly one `getUpdates` long-poll consumer
per bot token. Two Claude Code sessions polling the same bot produces
constant 409 Conflict races, with messages arriving at whichever session
is holding the lock at that moment. Unpredictable and unusable.

We also checked whether the upstream plugin supports Telegram's
forum/topic feature for routing within a single bot: it doesn't. The
plugin source contains zero references to `message_thread_id`, and the
plugin pairs 1:1 with a Claude Code process anyway — one session, one
context.

**Multi-bot is the clean alternative:** separate bot tokens, separate
processes, separate contexts, separate polling locks. No races, no
ambiguity. The tradeoff is that each container shows up as its own chat
in your Telegram sidebar instead of as sub-threads of a single chat.

## The mental model

```
Your machine
├── Container: main          Container: work          Container: personal
├── Bot:       @main_bot     @work_bot                @personal_bot
├── Token:     token_A       token_B                  token_C
├── State:     ~/.claude/channels/telegram/ or telegram-<label>/
├── cwd:       ~/.claude-bg/<label>/
├── tmux:      claude-bg-<label>
└── cl session: one at a time, independent history pool per cwd
```

## Creating containers

### First container — usually called `main`

```bash
clbg new main --notes "personal assistant"
# Create @main_bot with BotFather, copy token
clbg link main 123456789:AAH...
# Bootstrap allowlist
clbg exec main /telegram:access policy pairing
# DM @main_bot → get pairing code
clbg exec main /telegram:access pair <code>
clbg exec main /telegram:access policy allowlist
# Start
clbg start main
```

### Additional containers — one command per new bot

```bash
clbg new work --notes "business"
# Create @work_bot with BotFather (completely separate bot!)
clbg link work 987654321:BBH...
# Allowlist bootstrap (note: each container has its own allowlist)
clbg exec work /telegram:access policy pairing
# DM @work_bot → new pairing code
clbg exec work /telegram:access pair <code>
clbg exec work /telegram:access policy allowlist
clbg start work
```

Repeat for each additional bot. Each container is fully isolated:

- Separate bot token → no polling race
- Separate `~/.claude-bg/<label>/` cwd → isolated session pool
- Separate `~/.claude/channels/telegram-<label>/` → isolated allowlist
- Separate `claude-bg-<label>` tmux session → start/stop independently

## Managing the fleet

List all containers with `clbg list`:

```
LABEL     BOT              STATUS    LAST SESSION  COST    TOKENS  NOTES
main      @main_bot        running   c37f19ee…    $12.40  8.2M    personal assistant
work      @work_bot        running   d48ab503…    $21.53  22.2M   business stuff
personal  @personal_bot    stopped   -             -       -      side projects
```

Deep status for one:

```bash
clbg status main
```

Shows lastSessionId, cost, token breakdown, plus the last few entries from
sessions-index.json (firstPrompt + summary) if it exists.

Restart one without touching the others:

```bash
clbg restart work
```

Stop one:

```bash
clbg stop personal
```

Remove one permanently (prompts for confirmation by having you type the
label):

```bash
clbg rm personal
```

## Verifying there's no polling race

After starting multiple containers:

```bash
ps aux | grep "bun server.ts" | grep -v grep
# Expect: one line per running container
```

Each bun process has its own Telegram API connections:

```bash
for pid in $(pgrep -f "bun server.ts"); do
  echo "=== $pid ==="
  lsof -a -p $pid -i -P 2>/dev/null | grep 149.154
done
# Expect: each pid has its own ESTABLISHED connections
```

If any two processes are reading from the **same** state dir, you've got a
misconfiguration:

```bash
ps eww $(pgrep -f "bun server.ts") | grep TELEGRAM_STATE_DIR
```

Each line should show a different `TELEGRAM_STATE_DIR=...`. If two match,
one of the containers is misconfigured — check `~/.claude-bg/containers.json`.

## Gotchas

- **Don't share bot tokens across containers.** That's the exact polling
  race we're trying to avoid. Each container needs its own bot from
  BotFather.
- **Each container has its own allowlist.** A Telegram user ID that's
  allowed on the main bot is not automatically allowed on the work bot.
  You have to bootstrap each one (Step 7 in the single-bot setup, run per
  container).
- **Apply the typing patch once, globally.** The patch lives in the
  plugin's `server.ts`, which is shared across all containers, so you
  only apply it once and every bg runner benefits.
- **Plugin upgrades invalidate the patch for everyone.** Keep
  `server.ts.orig` around and script the re-application if you upgrade
  frequently. A PR that automates this is welcome.
- **One container per bot, and the bot follows the container.** If you
  want to move a bot to a different container, use `clbg link` to update
  the token in the target, then clear the old container's `.env`.

## When multi-bot is overkill

If you only need one always-on Telegram channel, just run one container
(`main`) and stop. The single-bot case is still a full `clbg new` + `link`
+ `start` workflow — it's just one. Nothing about `clbg` penalizes you
for using only one container.

Multi-bot pays off when you need:

- Separate conversation histories for work and personal
- A test/experimental channel isolated from a production-ish one
- Different allowlists (e.g. sharing a work bot with a colleague without
  exposing your personal main bot)
- A PR review or code-review bot scoped to one repo, isolated from the
  rest of your dev environment
