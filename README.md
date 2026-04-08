# claude-telegram-kit

Production-ready setup for running [Claude Code](https://claude.com/claude-code)
as a persistent Telegram assistant — **detached in tmux**, **always on**,
**with proper typing indicators**, **without session hijacking**, and
**with multi-bot support** for running several independent sessions side by side.

Built on top of the official
[`telegram@claude-plugins-official`](https://github.com/anthropics/claude-plugins)
plugin. This kit covers the operational gaps: flags you must pass, gotchas
that silently break the channel, and a patch that keeps the "typing…"
indicator alive across long-running thinks.

---

## Why this exists

The official Telegram plugin works, but getting it to run **reliably in the
background** hits a long chain of non-obvious pitfalls. This kit packages
every landmine we hit into:

- A single setup Skill (`/telegram-bg-setup`) that walks through the whole
  thing end to end
- A tmux launcher (`clbg`) with the correct flags already baked in
- A patch for the `typing…` indicator (upstream only fires it once, giving
  you ~5 seconds of feedback even when Claude thinks for 3 minutes)
- A multi-bot pattern doc so you can run N independent sessions
- A troubleshooting log of the actual failures and how to spot them

**Nothing here bypasses the plugin** — we use it as-is plus one documented
patch. Upgrading the plugin just means reapplying the patch (or dropping it
if upstream merges the fix).

---

## Quick status: what this fixes

| Symptom | Root cause | Fix in this kit |
| --- | --- | --- |
| MCP server starts but messages never reach Claude | Session launched without `--channels` flag → `Channel notifications skipped` | `clbg` always passes `--channels plugin:telegram@claude-plugins-official` |
| Background session freezes on first Bash call | Permission prompt has no one to answer it in detached tmux | `--dangerously-skip-permissions` + strict `allowFrom` allowlist as the real defense |
| Background session "continues" a totally unrelated conversation | `claude --continue` picks the most-recent jsonl in the cwd's session pool, and `$HOME` pools every session ever launched there | Dedicated cwd `~/.claude-bg/` isolates the bg session pool |
| Telegram "typing…" disappears after 5 seconds even though Claude is still thinking | Upstream plugin calls `sendChatAction('typing')` exactly once per message | `patches/telegram-typing-indicator.patch` refreshes every 4.5s until `reply` is sent (30-min hard cap) |
| Two Claude sessions both polling the same bot — race conditions, missed replies | Telegram Bot API only allows one `getUpdates` client per token | `docs/MULTI-BOT.md`: use `TELEGRAM_STATE_DIR` + separate bot per session |
| First launch from a new cwd re-prompts for folder trust | Claude Code stores trust per-directory | Documented; one attach to press Enter and you're done |

---

## Prerequisites

- [Claude Code](https://claude.com/claude-code) installed
- [Bun](https://bun.sh) (required by the Telegram plugin)
- `tmux` (for the background runner)
- A Telegram account and the ability to talk to [@BotFather](https://t.me/BotFather)

---

## Quick start (single bot, one background session)

**1. Create a bot with BotFather**

Open [@BotFather](https://t.me/BotFather), send `/newbot`, pick a name and
username. Copy the token it gives you — it looks like
`123456789:AAH...`.

**2. Install the plugin and give it the token**

```bash
claude
```
Then inside Claude:
```
/plugin install telegram@claude-plugins-official
/reload-plugins
/telegram:configure 123456789:AAH...
```

**3. Install this kit**

```bash
git clone https://github.com/intelli-bruce/claude-telegram-kit.git
cd claude-telegram-kit

# Put the launcher on your PATH (pick one)
cp scripts/claude-bg.sh ~/.local/bin/clbg && chmod +x ~/.local/bin/clbg
# or alias it
echo "alias clbg='$(pwd)/scripts/claude-bg.sh'" >> ~/.zshrc

# Create the dedicated bg working directory
mkdir -p ~/.claude-bg
```

**4. Apply the typing indicator patch (recommended)**

```bash
PLUGIN_DIR="$HOME/.claude/plugins/cache/claude-plugins-official/telegram/0.0.4"
cp "$PLUGIN_DIR/server.ts" "$PLUGIN_DIR/server.ts.orig"
patch -d "$PLUGIN_DIR" -p0 < patches/telegram-typing-indicator.patch
```

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for what the patch
actually does and why upstream's one-shot call isn't enough.

**5. Set up access control**

Inside Claude (any session):
```
/telegram:access policy allowlist
```

DM your bot from Telegram once to get a pairing code, then:
```
/telegram:access pair <6-char-code>
```

From now on only your own Telegram user ID is allowed to talk to the bot.
See [`docs/SECURITY.md`](docs/SECURITY.md) for why this matters, especially
if you're using `--dangerously-skip-permissions`.

**6. First launch — press Enter once for folder trust**

```bash
clbg start      # creates the tmux session
clbg attach     # enter it, press "Yes, I trust this folder"
# Then: Ctrl+B D to detach (tmux prefix + D)
```

**7. Test it**

DM your bot. You should see:
- A 👀 reaction appear on your message (the `ackReaction`, configurable)
- A persistent `typing…` indicator in the chat header until Claude replies
- The reply

If you don't, jump to [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md).

---

## Running multiple independent sessions

One bot token = one poller. If you want a "work" session and a "personal"
session both reachable at the same time, you need **separate bots with
separate state directories**. This is officially supported by the plugin
(via the `TELEGRAM_STATE_DIR` env var), just not documented in one place.

Full walkthrough: [`docs/MULTI-BOT.md`](docs/MULTI-BOT.md).

Quick version:
```bash
# Create a second bot via BotFather, get a second token

# Dedicate a state dir for it
mkdir -p ~/.claude/channels/telegram-work
echo "TELEGRAM_BOT_TOKEN=<second_token>" > ~/.claude/channels/telegram-work/.env
chmod 600 ~/.claude/channels/telegram-work/.env

# Launch a second bg session pointed at it
TELEGRAM_STATE_DIR=~/.claude/channels/telegram-work \
  clbg start
```

---

## What you get

```
claude-telegram-kit/
├── scripts/
│   ├── claude-bg.sh              # the tmux launcher (alias as 'clbg')
│   └── telegram-new-bot.sh       # scaffolds a new bot's state dir
├── skills/
│   └── telegram-bg-setup/
│       └── SKILL.md              # invocable skill that walks through the whole setup
├── patches/
│   └── telegram-typing-indicator.patch
├── docs/
│   ├── ARCHITECTURE.md           # how the pieces fit together
│   ├── MULTI-BOT.md              # independent sessions with separate bots
│   ├── TROUBLESHOOTING.md        # every failure mode we hit and how to diagnose it
│   └── SECURITY.md               # allowlist hygiene, --dangerously-skip-permissions tradeoffs
├── LICENSE                       # MIT (patch file notes Apache 2.0 for upstream)
└── README.md                     # this file
```

---

## Not included, on purpose

- **No bot tokens.** Obvious but worth stating. `.gitignore` excludes `.env`
  and `access.json`.
- **No fork of the plugin.** We patch it locally and document the patch.
  Keeps upgrade paths clean.
- **No container / systemd unit.** tmux is the right size for a single-user
  laptop. If you're running this on a server, systemd is a one-off exercise.
- **No automatic token rotation, no webhook mode.** The Telegram Bot API's
  long-polling limitation is the entire reason for the multi-bot pattern;
  working around it belongs in a different project.

---

## Contributing

PRs welcome, especially:
- Additional troubleshooting entries — if you hit a new failure mode, a PR
  with the error signature and fix is the most valuable contribution
- Upstream patch upgrades if the Telegram plugin version bumps
- Windows/WSL testing (this kit has only been verified on macOS)

---

## License

MIT, see [`LICENSE`](LICENSE). The included patch file modifies
Apache-2.0-licensed upstream code; see the note at the bottom of `LICENSE`
for the derivative-work implications.
