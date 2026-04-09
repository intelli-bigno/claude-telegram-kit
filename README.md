# claude-telegram-kit

Run [Claude Code](https://claude.com/claude-code) as a persistent Telegram
assistant. Multiple independent sessions, each bound to its own Telegram bot,
each isolated from the others, each always-on in tmux. One command to create
a new container, one command to list them all.

Built on the official
[`telegram@claude-plugins-official`](https://github.com/anthropics/claude-plugins)
plugin. This kit is the operational glue that makes it actually work
unattended: the flags you have to pass, the state files you have to pre-seed
to avoid one-shot dialogs, the container model for running N independent
bots, and a patch for Telegram's 5-second "typing…" cap.

---

## Quick demo

```bash
$ clbg new work --notes "business stuff"
[clbg] scaffolding cwd: /Users/me/.claude-bg/work
[clbg] scaffolding state dir: /Users/me/.claude/channels/telegram-work
[clbg] injecting trust into ~/.claude.json for /Users/me/.claude-bg/work
[clbg] registered in containers.json

Next steps:
  1. Open @BotFather on Telegram, send /newbot, create a new bot
  2. Copy the token (looks like 123456789:AAH...)
  3. Link it to this container:
       clbg link work <token>
  ...

$ clbg link work 123456789:AAH...
[clbg] wrote token to /Users/me/.claude/channels/telegram-work/.env
[clbg] bot username: @my_work_assistant_bot
Linked. Next:
  clbg start work    # start the bg session

$ clbg start work
# (attaches to a new tmux session, claude boots, press Ctrl+B D to detach)

$ clbg list
LABEL  BOT                      STATUS   LAST SESSION  COST    TOKENS  NOTES
main   @my_main_bot             running  a7f3c812…    $12.40  8.2M    personal assistant
work   @my_work_assistant_bot   running  d48ab503…    $0.00   0       business stuff
```

You now have two completely independent Claude sessions, each reachable from
a different Telegram bot, running unattended in tmux. No polling conflicts,
no session hijacking, no stuck one-shot dialogs.

---

## What this fixes

Operating Claude Code as a detached Telegram listener looks simple and turns
out to be a minefield. This kit is every fix we had to make, packaged.

| Symptom | Root cause | Fix in this kit |
| --- | --- | --- |
| MCP server starts but messages never reach Claude | Session launched without `--channels` flag → `Channel notifications skipped` in MCP logs | `clbg` always passes `--channels plugin:telegram@claude-plugins-official` |
| Background session freezes on first Bash call | Permission prompt has no one to answer it in detached tmux | `--dangerously-skip-permissions` + strict `allowFrom` allowlist as the real defense |
| Background session "continues" a totally unrelated conversation | `claude --continue` picks the most-recent jsonl in the cwd's session pool, and `$HOME` pools every session ever launched there | Per-container cwd under `~/.claude-bg/<label>/` + `--resume <explicit UUID>` (never `--continue`) |
| `clbg restart` asks "Yes, I trust this folder?" on a detached session | Folder trust prompt blocks until human input | Pre-inject `hasTrustDialogAccepted: true` into `~/.claude.json` at `clbg new` time |
| `clbg restart` asks "Resume from summary / full?" on a large old session | Resume mode prompt blocks until human input | Use `--resume <exact UUID>` (the prompt only fires on `--continue` fallback) |
| Telegram "typing…" disappears after 5 seconds while Claude is still thinking | Upstream plugin calls `sendChatAction('typing')` exactly once per message | `patches/telegram-typing-indicator.patch` refreshes every 4.5s until `reply` is sent (30-min hard cap) |
| Two Claude sessions fighting over the same bot token | Telegram Bot API only allows one `getUpdates` client per token | Each container has its own bot and `TELEGRAM_STATE_DIR` — no races |
| "Which bg session is talking to which bot?" management chaos | No visibility | `clbg list` shows the whole fleet: bot, status, last session id, cost, tokens |

---

## Prerequisites

- [Claude Code](https://claude.com/claude-code) installed, and run at least
  once (needed to create `~/.claude.json`)
- [Bun](https://bun.sh) (required by the Telegram plugin)
- `tmux`
- Python 3.9+ (macOS ships with 3.9+; Linux usually has it)
- Telegram account + ability to talk to [@BotFather](https://t.me/BotFather)

---

## Install

```bash
# clone
git clone https://github.com/intelli-bruce/claude-telegram-kit.git
cd claude-telegram-kit

# put clbg on your PATH (either option works)
ln -s "$PWD/scripts/claude-bg.sh" ~/.local/bin/clbg
# or
echo "alias clbg='$PWD/scripts/claude-bg.sh'" >> ~/.zshrc && source ~/.zshrc

# install the Telegram plugin inside Claude Code if you haven't already:
claude
#   /plugin install telegram@claude-plugins-official
#   /reload-plugins
#   /quit
```

Apply the typing indicator patch (recommended — without it you'll stare at
a dead chat for minutes during any long Claude think):

```bash
PLUGIN_DIR="$HOME/.claude/plugins/cache/claude-plugins-official/telegram/0.0.4"
cp "$PLUGIN_DIR/server.ts" "$PLUGIN_DIR/server.ts.orig"
patch -d "$PLUGIN_DIR" -p1 < patches/telegram-typing-indicator.patch
```

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the mechanics of the
patch and why upstream's one-shot call isn't enough.

---

## Upgrading (마이그레이션)

이전 버전에서 업그레이드하는 경우, 토큰 격리 방식이 변경되었습니다.
기존에 `.env`에 `TELEGRAM_BOT_TOKEN=`(빈 값)으로 컨테이너를 생성했다면,
새 버전에서는 `.env`가 `DISABLED` 상태로 유지되고 실제 토큰은
`containers.json`에만 저장됩니다.

**기존 컨테이너 마이그레이션 방법:**

```bash
# 각 컨테이너에 대해 토큰을 다시 link 합니다
clbg link <label> <token>
```

`clbg link`를 다시 실행하면 `containers.json`에 토큰이 저장되고,
이후 `clbg start` 시 자동으로 `.env`에 활성화됩니다.
별도의 데이터 손실은 없으며, 기존 세션 히스토리와 설정은 그대로 유지됩니다.

---

## Create your first container

```bash
clbg new main --notes "personal assistant"
```

The command:
1. Creates `~/.claude-bg/main/` (the container's cwd)
2. Creates `~/.claude/channels/telegram-main/` with a template `.env` and
   `access.json` (allowlist mode by default)
3. Pre-seeds `~/.claude.json` so Claude Code never prompts for folder trust
   or project onboarding in this cwd
4. Prints next-step instructions

Then:
```bash
# Create a bot with @BotFather, copy its token, then:
clbg link main 123456789:AAH...

# Bootstrap the allowlist (this adds your Telegram user ID)
clbg exec main /telegram:access policy pairing
# DM your bot from Telegram to get a pairing code
clbg exec main /telegram:access pair <code>
clbg exec main /telegram:access policy allowlist

# Start the background session
clbg start main
# (attaches to new tmux; press Ctrl+B D to detach)
```

Test by DMing your bot. You should see:
- A 👀 reaction on your message within a second or two (ack)
- "typing…" in the chat header, held until Claude's reply arrives
- Claude's reply

If any of those fail, see [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md).

---

## Running multiple independent sessions

Just do it again with a different label:

```bash
clbg new work --notes "business stuff"
# (second BotFather bot)
clbg link work 987654321:ZZH...
clbg exec work /telegram:access policy pairing
# DM the work bot, get code
clbg exec work /telegram:access pair <code>
clbg exec work /telegram:access policy allowlist
clbg start work
```

Each container is fully independent:
- Separate bot token (no polling race on the Telegram side)
- Separate cwd (`~/.claude-bg/<label>/`) → separate session history pool
- Separate tmux session (`claude-bg-<label>`) → start/stop independently
- Separate allowlist in each `access.json` → different people can be granted
  access to different bots

See [`docs/MULTI-BOT.md`](docs/MULTI-BOT.md) for the deeper walkthrough and
failure modes specific to multi-bot setups.

---

## Command reference

```bash
clbg new <label> [--notes "..."]       # scaffold a new container
clbg link <label> <bot-token>          # attach a token, verify it via Telegram getMe
clbg start <label> [--bg]              # new fresh session (new random UUID)
clbg resume <label> [--bg]             # --resume <lastSessionId> from ~/.claude.json
clbg restart <label> [--bg]            # stop + resume
clbg attach <label>                    # tmux attach
clbg stop <label>                      # tmux kill-session
clbg list (ls)                         # fleet overview
clbg status <label>                    # detailed per-container status
clbg rm <label> [-y]                   # nuke container (confirmed by typing label)
clbg exec <label> <prompt>             # one-shot `claude -p` in that container
```

By default `start`/`resume`/`restart` attach to the tmux session so you see
any first-run output. Add `--bg` to stay detached if you're scripting.

---

## What's in the box

```
claude-telegram-kit/
├── scripts/
│   └── claude-bg.sh                   # clbg — Python 3 container manager (~550 lines)
├── skills/
│   └── telegram-bg-setup/
│       └── SKILL.md                   # invocable skill that walks through the whole setup
├── patches/
│   └── telegram-typing-indicator.patch # 30-min persistent typing indicator
├── docs/
│   ├── ARCHITECTURE.md                # how it all fits together, including ~/.claude.json
│   ├── MULTI-BOT.md                   # independent sessions with separate bots
│   ├── TROUBLESHOOTING.md             # every failure mode we hit, with diagnostics
│   └── SECURITY.md                    # allowlist hygiene, --dangerously-skip-permissions tradeoffs
├── LICENSE                            # MIT (patch notes Apache 2.0 for upstream derivative work)
└── README.md                          # this file
```

---

## What this kit deliberately doesn't do

- **No fork of the Telegram plugin.** We patch it locally, document the patch,
  and document how to re-apply if upstream bumps. Keeps upgrade paths clean.
- **No single-bot "topic" routing.** Telegram's forum/topic feature is not
  recognized by the plugin (we checked the source). The plugin pairs 1:1 with
  a Claude Code process, so "multiple topics in one bot, each mapped to a
  different cl session" isn't a shape it supports. Multi-bot is the clean
  alternative.
- **No systemd / Docker / daemonization.** tmux is right-sized for a single
  laptop. If you need this on a server, wrap it in systemd yourself —
  the script doesn't fight you.
- **No token rotation, no webhook mode.** The long-polling limitation is
  why multi-bot exists. Working around it belongs in a different project.

---

## Contributing

PRs welcome, especially:
- New troubleshooting entries — if you hit a failure mode not covered, a PR
  with the error signature and fix is the most valuable contribution you can make
- Upstream patch upgrades if the Telegram plugin version bumps
- Linux / WSL testing (this kit has only been verified on macOS)

---

## License

MIT, see [`LICENSE`](LICENSE). The included patch file modifies
Apache-2.0-licensed upstream code; see the note at the bottom of `LICENSE`
for derivative-work implications.
