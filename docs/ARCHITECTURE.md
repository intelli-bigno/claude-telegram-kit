# Architecture

What actually happens when you DM your bot, where every piece of state
lives, and why the kit is structured the way it is. If you understand this
doc, troubleshooting becomes obvious and adding features becomes safe.

## The pieces

```
┌─────────────────┐       Telegram Bot API (long-poll, 1 client per token)
│  Telegram app   │ ─────────────────────────────────────┐
└─────────────────┘                                       │
         ▲                                                ▼
         │                                    ┌────────────────────────┐
         │  reply                              │  bun server.ts         │  ← one per container,
         │                                    │  (Telegram plugin MCP) │     spawned by Claude
         │                                    └────────────────────────┘     Code when --channels
         │                                                │                  is on and plugin loaded
         │                                                │ MCP notification
         │                                                │ notifications/claude/channel
         │                                                ▼
         │                                    ┌────────────────────────┐
         │                                    │  Claude Code CLI       │  ← running in tmux
         │                                    │  (with --channels flag)│     session claude-bg-<label>
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

---

## File layout

### Claude Code's own state

```
~/.claude.json                              ← the master state hub
  projects:
    /Users/you/.claude-bg/main:             ← one entry per cwd Claude has seen
      hasTrustDialogAccepted: true          ← pre-seeded by clbg new
      hasTrustDialogHooksAccepted: true     ← pre-seeded by clbg new
      hasCompletedProjectOnboarding: true   ← pre-seeded by clbg new
      projectOnboardingSeenCount: 1
      allowedTools: []
      mcpServers: {}
      lastSessionId: "c37f19ee-..."         ← target for `clbg resume`
      lastCost: 12.40                       ← used by `clbg list`
      lastTotalInputTokens: 799
      lastTotalOutputTokens: 126413
      lastTotalCacheReadInputTokens: 22087162
      lastModelUsage: {model → usage dict}
      lastDuration: 53989056
      (etc — 35 fields total, all Claude Code-managed except for our 3 trust flags)
    /Users/you/.claude-bg/work:             ← another container
      ...

~/.claude/projects/                         ← per-cwd session pool
  -Users-you--claude-bg-main/               ← encoded cwd path
    <sessionId>.jsonl                       ← one file per session, in order
    sessions-index.json                     ← summary index (see below)
  -Users-you--claude-bg-work/
    ...
```

### clbg's own state

```
~/.claude-bg/
├── containers.json                         ← our metadata registry
│   {
│     "version": 1,
│     "containers": {
│       "main": {
│         "createdAt": "...",
│         "botUsername": "@my_main_bot",
│         "stateDir": "~/.claude/channels/telegram-main",
│         "cwd": "~/.claude-bg/main",
│         "tmuxSession": "claude-bg-main",
│         "notes": "..."
│       }
│     }
│   }
├── main/                                   ← container cwd
│   └── README.md                           ← marker, nothing real lives here
└── work/
    └── README.md
```

### Telegram plugin's state (per container)

```
~/.claude/channels/
├── telegram-main/                          ← first container
│   ├── .env                                ← TELEGRAM_BOT_TOKEN=... (0600)
│   ├── access.json                         ← dmPolicy, allowFrom, ackReaction, etc.
│   └── approved/                           ← pairing ACK dropzone
└── telegram-<label>/                       ← additional containers
    ├── .env
    ├── access.json
    └── approved/
```

Each additional container points the plugin at its own state dir via the
`TELEGRAM_STATE_DIR` environment variable, which is set by `clbg start`
when it spawns the tmux session.

### Patched plugin source

```
~/.claude/plugins/cache/claude-plugins-official/telegram/0.0.4/
├── server.ts                               ← patched (typing indicator)
├── server.ts.orig                          ← our backup, for re-applying after upgrades
└── ...
```

---

## Why each piece exists

### `--channels` flag

Claude Code launches the Telegram MCP server as a subprocess whenever the
plugin is enabled. The server connects to Telegram and starts polling. The
plugin declares channel capabilities (`claude/channel`,
`claude/channel/permission`), but Claude Code only *registers* those
notifications if the session was launched with:

```
claude --channels plugin:telegram@claude-plugins-official
```

Without that flag, here's what you see in the MCP logs:

```
~/Library/Caches/claude-cli-nodejs/.../mcp-logs-plugin-telegram-telegram/*.jsonl
{"debug":"Channel notifications skipped: server plugin:telegram:telegram not in --channels list for this session"}
```

The bun process is still running. It's still polling Telegram. It's still
receiving messages. Claude Code just silently drops them on the floor.

**This is by far the most confusing failure mode.** `clbg` always passes
this flag.

### `--dangerously-skip-permissions`

When Claude Code wants to run a tool that isn't on the allow-list, it shows
a terminal prompt:

```
Do you want to proceed?
❯ 1. Yes
  2. Yes, and don't ask again for: ...
  3. No
```

In an interactive terminal, you press 1. In a detached tmux session, **there
is nobody to press 1**. Claude hangs forever, messages pile up.

`--dangerously-skip-permissions` auto-approves every tool call. The cost
is that the allowlist in `access.json` is now load-bearing: it's the only
thing stopping a Telegram user with the bot token from running arbitrary
code. See [`SECURITY.md`](SECURITY.md).

### Per-container cwd

`claude --continue` picks "the most recently modified session jsonl in the
cwd's session pool" and resumes it. The pool lives at
`~/.claude/projects/-Users-<you>/` for sessions launched in `$HOME`, and
similar encoded paths for other directories.

Every Claude Code session you've ever launched from `$HOME` lands in the
same pool — we counted 13+ in a week on a single machine. When a background
runner restarts with `--continue` against that shared pool, it can hijack
a completely unrelated session just because it was modified more recently.
We hit this exact bug: a bg restart resumed a session about global Claude
Code config analysis and started answering Telegram messages from that
context.

**`clbg` solves this two ways at once:**

1. Each container gets its own cwd (`~/.claude-bg/<label>/`), so the
   session pool `~/.claude/projects/-Users-<you>--claude-bg-<label>/`
   is single-tenant.
2. `clbg resume` **never uses `--continue`.** It reads `lastSessionId`
   from `~/.claude.json` projects entry and passes it explicitly as
   `--resume <uuid>`. The correct session is always picked by ID, not
   by mtime luck.

### Pre-seeded trust (the magic)

Claude Code has three boolean fields per cwd in `~/.claude.json` projects:

- `hasTrustDialogAccepted` — controls "Yes, I trust this folder?"
- `hasTrustDialogHooksAccepted` — controls the hook-specific trust dialog
- `hasCompletedProjectOnboarding` — controls per-project onboarding steps

In a normal interactive session you press Enter through each of these once
and Claude Code flips them to true for you. **In a detached tmux session,
there's nobody to press Enter.** These dialogs don't care about
`--dangerously-skip-permissions` — that flag is about tool permissions, not
workspace trust.

`clbg new` writes all three to `true` in `~/.claude.json` before the
session ever starts. None of the dialogs fire. This is the single most
important trick in the kit — without it, every `clbg restart` is Russian
roulette.

The write is atomic (temp file + rename) and creates a backup
(`~/.claude.json.clbg.bak`) on first touch per invocation. The fields we
set don't overlap with anything Claude Code writes during normal operation,
so last-write-wins is safe.

### Typing indicator patch

Telegram's `sendChatAction('typing')` tells Telegram to show "typing…" in
the chat header for ~5 seconds. The upstream plugin calls it exactly once,
on message receipt. There's even a comment in the code:

```typescript
// signals "processing" until we reply (or ~5s elapses)
void bot.api.sendChatAction(chat_id, 'typing').catch(() => {})
```

For any non-trivial question, "or ~5s" is the whole problem. Claude thinks,
the indicator disappears, the user stares at a dead chat. We had to tell
users "if it says 'seen' and nothing else, it's probably still working" —
that's a bug.

The patch adds a 4.5-second refresh loop and a 30-minute hard cap:

```typescript
const typingTimers = new Map<string, NodeJS.Timeout>()
const typingExpiry = new Map<string, NodeJS.Timeout>()

function startTyping(chat_id: string): void {
  stopTyping(chat_id)
  const timer = setInterval(
    () => void bot.api.sendChatAction(chat_id, 'typing').catch(() => {}),
    4500,
  )
  typingTimers.set(chat_id, timer)
  const cap = setTimeout(() => stopTyping(chat_id), 30 * 60 * 1000)
  typingExpiry.set(chat_id, cap)
}

function stopTyping(chat_id: string): void {
  const t = typingTimers.get(chat_id)
  if (t) { clearInterval(t); typingTimers.delete(chat_id) }
  const e = typingExpiry.get(chat_id)
  if (e) { clearTimeout(e); typingExpiry.delete(chat_id) }
}
```

`startTyping()` is called at the beginning of every inbound message
handler; `stopTyping()` is called inside the `reply` tool handler. The
30-minute cap is the lesson from our first attempt with 5 minutes — Claude
legitimately thinks for 10+ minutes on complex multi-tool workflows
(codegen, contract drafting, deep research). 5min cut the indicator off
mid-work and defeated the patch's purpose. 30min is past any realistic
single-turn think but still bounds genuinely runaway loops.

Full diff: `patches/telegram-typing-indicator.patch`.

---

## Polling and the 409 problem

The Telegram Bot API is long-polling based: a client calls `getUpdates`
with a timeout, the server holds the connection until a new update or the
timeout expires. The non-obvious rule:

> **Only one `getUpdates` consumer per bot token at a time.** A second
> caller gets `409 Conflict` until the first one goes away.

The plugin has a retry loop for this:

```typescript
if (err instanceof GrammyError && err.error_code === 409) {
  process.stderr.write(
    `telegram channel: 409 Conflict${detail}, retrying in ${delay / 1000}s\n`,
  )
  // ... exponential backoff
}
```

In practice this means if you run two Claude Code sessions that both load
the plugin, they race each other. Whichever starts polling first holds the
lock; the other retries with backoff. Eventually the first session's long
poll times out and briefly releases the lock; the second grabs it; now the
first is in backoff; this flip-flops indefinitely and messages get
distributed randomly.

**The plugin has no concept of "this session gets messages, that session
doesn't"**, because at startup there's no way to know. It just races.

The kit's solution: **one bot per container**. Each container points at
its own `TELEGRAM_STATE_DIR` with a different token, so there's no race.
See [`MULTI-BOT.md`](MULTI-BOT.md) for the full walkthrough.

---

## Session jsonl format (reverse-engineered)

Sessions are line-delimited JSON files at
`~/.claude/projects/-Users-<you>--<encoded-cwd>/<sessionId>.jsonl`. Each
line is one event. The event types we've seen:

| Type | Meaning |
|---|---|
| `permission-mode` | Session boundary marker (start / end). Contains `permissionMode: "default" \| "bypassPermissions"` |
| `file-history-snapshot` | Tracked file backups, cumulative/delta depending on `isSnapshotUpdate` |
| `user` | User message. Contains cwd, entrypoint, version, session context |
| `assistant` | Claude response with model, content, and per-turn token `usage` (input/output/cache counts) |
| `attachment` | Tool/object metadata attached to the parent message (deferred_tools_delta, etc.) |
| `system` | Internal events — subtypes include `turn_duration` (ms + messageCount) and `local_command` (shell execution logs) |
| `last-prompt` | Clean-shutdown terminal marker — the final user prompt saved for resume |
| `queue-operation` | Telegram bg specific — enqueue/dequeue for the channel message queue |

### Lifecycle states from the file alone

- **Active**: file mtime > last event timestamp, last event is not
  `permission-mode`
- **Clean end**: last events are `last-prompt` then `permission-mode`
- **Killed mid-turn**: last event is `assistant` or `system`, no `last-prompt`

### sessions-index.json

Claude Code maintains a per-cwd index at
`~/.claude/projects/<encoded-cwd>/sessions-index.json`:

```json
{
  "version": 1,
  "entries": [
    {
      "sessionId": "3232fe0d-...",
      "fullPath": "/Users/.../3232fe0d-....jsonl",
      "fileMtime": 1769581075526,
      "firstPrompt": "check current cpu usage",
      "summary": "Investigated CPU hotspot, identified runaway process",
      "messageCount": 4,
      "created": "2025-12-28T23:54:43.153Z",
      "modified": "2025-12-28T23:55:51.307Z",
      "gitBranch": "",
      "projectPath": "/Users/...",
      "isSidechain": false
    },
    ...
  ]
}
```

This is where **session summaries actually live** (not in the jsonl
itself). `clbg status <label>` reads this file to show the last few
sessions with their summaries and first prompts.

Note: sessions-index.json is created by Claude Code under conditions we
haven't fully characterized — a brand-new container may not have one yet.
`clbg status` handles its absence gracefully.

### Token accounting

Per-turn tokens are in each `assistant` event's `usage` field:

```json
"usage": {
  "input_tokens": 706,
  "output_tokens": 176752,
  "cache_creation_input_tokens": 4407647,
  "cache_read_input_tokens": 43848054
}
```

The running total shown by `clbg list` comes from `~/.claude.json`
projects entry's `lastTotalInputTokens`, `lastTotalOutputTokens`, and
`lastTotalCacheReadInputTokens` — Claude Code updates these as the session
runs, so we don't have to sum event-by-event.

---

## Why not Telegram topics?

We investigated. The official plugin's source has zero references to
`message_thread_id`, `thread_id`, `topic`, or `forum`. It pairs 1:1 with a
Claude Code process and doesn't route on topic. Even if we patched it to
read `message_thread_id`, Claude Code itself has no concept of sub-contexts
within a session — one session = one context, by design.

Multi-bot is the clean alternative: separate processes, separate contexts,
separate polling locks, separate everything. What you lose is the ability
to group all bots under one chat in the Telegram sidebar; what you gain is
a model that actually matches the tools you're working with.

---

## 자동 재시작 (Auto-restart)

`clbg start` / `clbg resume` / `clbg restart`는 기본적으로 **wrapper 스크립트
기반 자동 재시작** 모드로 동작한다. Claude Code 프로세스가 crash, OOM, 또는
예기치 않은 이유로 종료되면 wrapper가 자동으로 재시작한다.

### 동작 원리

`clbg start <label>` 실행 시:

1. `_generate_wrapper(label)`이 `~/.claude-bg/<label>/run.sh`를 생성한다.
2. tmux 세션은 `bash run.sh`로 시작된다 (bare `claude` 대신).
3. wrapper 내부의 `while true` 루프가 Claude Code를 실행하고, 종료 시 재시작한다.

### 세션 복구

매 루프 반복마다 wrapper는:

- `~/.claude.json`에서 해당 container cwd의 `lastSessionId`를 python3로 읽는다.
- `lastSessionId`가 있고 대응하는 `.jsonl` 파일이 존재하면 `--resume`으로 기존
  세션을 이어간다.
- 그렇지 않으면 `--session-id`로 새 UUID 세션을 시작한다.

이 방식은 crash 후에도 기존 대화 컨텍스트를 유지할 수 있게 해준다.

### Crash loop 감지

연속 crash를 무한 재시작하지 않기 위한 보호 장치:

- Claude가 5분(`STABLE_SECONDS`) 이상 정상 실행되면 crash 카운터를 리셋한다.
- 카운터가 20회(`MAX_CRASHES`)를 초과하면 300초 대기 후 리셋한다.
- 재시작 이력은 `~/.claude-bg/<label>/restart.log`에 기록된다.

### 정상 종료 처리

wrapper에 `trap`이 걸려 있어, `EXIT`, `SIGTERM`, `SIGINT` 시
`~/.claude/channels/telegram-<label>/.env`의 `TELEGRAM_BOT_TOKEN`을 `DISABLED`로
교체한다. 이는 종료된 container의 bot이 Telegram 메시지를 계속 consume하는 것을
방지한다.

### `--no-restart` 플래그

자동 재시작 없이 기존 방식(bare `claude` 직접 실행)으로 동작시키려면:

```
clbg start <label> --no-restart
clbg resume <label> --no-restart
clbg restart <label> --no-restart
```

디버깅이나 일회성 세션에 유용하다.
