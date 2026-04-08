# Architecture

What actually happens when you DM your bot, and why each piece of this kit
exists. If you understand this doc, the troubleshooting guide will make sense.

## The pieces

```
┌─────────────────┐       Telegram Bot API (long-poll)
│  Telegram app   │ ─────────────────────────────────────┐
└─────────────────┘                                       │
         ▲                                                ▼
         │                                    ┌────────────────────────┐
         │  reply                              │  bun server.ts         │
         │                                    │  (Telegram plugin MCP) │
         │                                    └────────────────────────┘
         │                                                │
         │                                                │ MCP notification
         │                                                │ notifications/claude/channel
         │                                                ▼
         │                                    ┌────────────────────────┐
         │                                    │  Claude Code CLI       │
         │                                    │  (with --channels flag)│
         │                                    └────────────────────────┘
         │                                                │
         │                                                ▼
         │                                    ┌────────────────────────┐
         │  MCP tool call: 'reply'             │  Claude (the model)    │
         └────────────────────────────────────│  thinks, then calls    │
                                               │  the reply tool        │
                                               └────────────────────────┘
```

Each box matters. If any one of them is misconfigured, the whole thing goes
silent in a way that looks like something else is broken.

## The flags you must pass

Claude Code launches the Telegram MCP server as a subprocess whenever the
plugin is enabled. The server connects to Telegram's Bot API and starts
polling. **But** the plugin declares itself as a "channel provider" with
experimental capabilities `claude/channel` and `claude/channel/permission`,
and Claude Code only *registers* those channel notifications if the session
was launched with:

```
claude --channels plugin:telegram@claude-plugins-official
```

Without that flag, here's what you see in the MCP logs:

```
~/Library/Caches/claude-cli-nodejs/.../mcp-logs-plugin-telegram-telegram/*.jsonl

{"debug":"Channel notifications skipped: server plugin:telegram:telegram not in --channels list for this session"}
```

The bun process is still running. It's still polling Telegram. It's still
receiving your messages and firing `notifications/claude/channel` events.
Claude Code just silently drops them on the floor.

**This is by far the most confusing failure mode.** You see a process,
you see network connections, you see messages hitting the log — but Claude
never sees them. `clbg` always passes this flag.

## Why `--dangerously-skip-permissions` in the background runner

When Claude Code wants to run a tool that isn't on the allow-list, it shows
a terminal prompt:

```
Do you want to proceed?
❯ 1. Yes
  2. Yes, and don't ask again for: ...
  3. No
```

In an interactive terminal, you press 1 and move on. In a detached tmux
session, **there is nobody to press 1**. The Claude process hangs on the
prompt forever. Telegram messages still arrive at the plugin, still get ack
reactions applied, but Claude can't process them because it's blocked on
stdin waiting for a human.

We watched this happen live: the first background session answered a few
messages fine, then hit a `security find-generic-password` call, and that
was the end of it. Every subsequent Telegram message just stacked up
unacknowledged in the message queue.

`--dangerously-skip-permissions` is the only escape hatch. It means every
tool call is auto-approved, including arbitrary shell commands.

**Therefore the allowlist is the real security boundary.** The bot token
is a secret (anyone who has it can send messages as your bot, from anywhere
on the internet), and the allowlist decides which Telegram user IDs can
actually trigger Claude. If the allowlist is empty or misconfigured, a
compromised token is a remote code execution vulnerability. See
[`SECURITY.md`](SECURITY.md).

## Why a dedicated cwd

`claude --continue` picks "the most recently modified session jsonl in the
cwd's session pool" and resumes it. The pool is located at:

```
~/.claude/projects/-Users-<you>/          # for sessions launched in $HOME
~/.claude/projects/-Users-<you>-Projects-foo/  # for sessions launched in ~/Projects/foo/
```

The path is the cwd with `/` replaced by `-`. **Every Claude Code session
you've ever launched from `$HOME` lands in the same pool.** We counted 13
in a week on a single machine — sessions from Warp, iTerm, VS Code terminal,
cron jobs, random one-off questions, all in one pile.

When the background runner restarts with `--continue`, it looks at that
pile, picks the most-recently-touched jsonl, and starts talking as if it
was that conversation. We hit this exact bug: a bg restart grabbed a
session that had been analyzing global Claude Code config files earlier
in the day (totally unrelated to Telegram), because that jsonl happened
to be the most recently modified at the moment of restart.

Fix: launch the bg session with cwd set to a directory nothing else uses.
`clbg` does this by setting `WORK_DIR="${HOME}/.claude-bg"`. That pool
then contains exactly one conversation: the bg session's own history.
`--continue` can't get it wrong because there's nothing wrong to pick.

## The typing indicator patch

Telegram's `sendChatAction('typing')` API call tells Telegram to show
"typing…" in the chat header for roughly 5 seconds. If you want it to stay
visible longer, you must keep calling the endpoint.

The upstream plugin calls it exactly once, on message receipt:

```typescript
// server.ts — upstream behavior
void bot.api.sendChatAction(chat_id, 'typing').catch(() => {})
```

There's even a comment: `// signals "processing" until we reply (or ~5s elapses)`.
That "or ~5s" is the whole problem. For anything that takes more than 5
seconds (which is "every non-trivial question"), the indicator vanishes
while Claude is still working. From the user's perspective, the bot looks
dead.

Our patch does three things:

1. Adds two module-level maps for tracking active typing intervals:
   ```typescript
   const typingTimers = new Map<string, NodeJS.Timeout>()
   const typingExpiry = new Map<string, NodeJS.Timeout>()
   ```

2. `startTyping(chat_id)` starts a `setInterval` that fires every 4.5s
   (just under Telegram's 5s expiry) until explicitly stopped. It also
   arms a 5-minute hard cap via `setTimeout` so runaway intervals can't
   pile up if something crashes mid-reply.

3. `stopTyping(chat_id)` is called from the `reply` tool handler. As soon
   as Claude sends a reply chunk, the indicator can stop — the user is
   about to see the actual message.

The patch is ~30 lines and preserves the upstream one-shot call (so if the
patched code crashes, you still get at least one typing event). Full diff:
`patches/telegram-typing-indicator.patch`.

## Polling and the 409 problem

The Telegram Bot API is a classic long-polling design: a client calls
`getUpdates` with a timeout, and the server holds the connection until
either a new update arrives or the timeout expires. There's one
non-obvious rule:

> Only one `getUpdates` consumer per bot token at a time. A second caller
> gets `409 Conflict` until the first one goes away.

The plugin's source is aware of this — there's a dedicated retry loop:

```typescript
// server.ts
if (err instanceof GrammyError && err.error_code === 409) {
  process.stderr.write(
    `telegram channel: 409 Conflict${detail}, retrying in ${delay / 1000}s\n`,
  )
  // ... exponential backoff
}
```

In practice this means if you run **two Claude Code sessions that both
have the plugin enabled**, they race each other:

- Whichever started polling first holds the lock
- The other retries with backoff
- Eventually the first session's long-poll times out and briefly releases
  the lock
- The second session grabs it
- Now the first session is in backoff
- This flip-flops indefinitely, and messages get distributed randomly

**The plugin has no concept of "this session gets messages, that session
doesn't"**, because at startup there's no way to know. It just races.

The fix for running multiple sessions is one of:

- **Single active session** — shut down the plugin's bun process in all
  sessions except the one you care about. Heavy-handed but simple.
- **One bot per session** (recommended) — each session points at its own
  `TELEGRAM_STATE_DIR` with a different token, so there's no race in the
  first place. See [`MULTI-BOT.md`](MULTI-BOT.md).

## File layout summary

```
~/.claude/channels/telegram/              # default state dir
├── .env                                    # TELEGRAM_BOT_TOKEN=...
├── access.json                             # dmPolicy, allowFrom, etc.
└── approved/                               # server writes pairing ACKs here

~/.claude-bg/                              # dedicated cwd for bg session
└── README.md                               # marker file, nothing else lives here

~/.claude/projects/-Users-<you>--claude-bg/  # bg session's jsonl pool
└── <uuid>.jsonl                            # the one conversation in this pool

~/.claude/plugins/cache/.../telegram/0.0.4/
├── server.ts                               # patched plugin source
├── server.ts.orig                          # our backup for re-applying after upgrades
└── ...
```
