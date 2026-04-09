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
│         "stateDir": "~/.claude/channels/telegram",
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
├── telegram/                               ← first container ("main" by convention)
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

## CLAUDE.md 페르소나 및 메모리

각 컨테이너는 생성 시 자동으로 `CLAUDE.md` 파일과 `memory/` 디렉토리를 갖는다.

### 페르소나 템플릿

`templates/` 디렉토리에 세 가지 내장 템플릿이 있다:

| 템플릿 | 용도 |
|---|---|
| `default.md` | 범용 도우미. 사용자 언어에 맞춰 응답 |
| `coder.md` | 코딩 전문. 코드 분석, 버그 수정, 기능 개발 |
| `researcher.md` | 리서치 전문. 조사, 비교 분석, 보고서 작성 |

컨테이너 생성 시 `--persona` 플래그로 선택하거나, `--claude-md`로 커스텀 템플릿 경로를
지정할 수 있다:

```
clbg new mybot --persona coder
clbg new mybot --claude-md ~/my-templates/custom.md
```

템플릿 내 `{label}` 플레이스홀더는 실제 컨테이너 라벨로 치환된다.
이미 `CLAUDE.md`가 존재하는 경우 덮어쓰지 않는다.

### memory/ 디렉토리

```
~/.claude-bg/<label>/
├── CLAUDE.md          ← 페르소나 + 지시사항
└── memory/
    └── MEMORY.md      ← 빈 인덱스 파일 (Claude가 채워감)
```

`CLAUDE.md`의 "메모리 관리" 섹션이 Claude에게 `memory/` 활용을 지시한다.
세션이 resume될 때 Claude는 `memory/`를 먼저 읽어 이전 맥락을 파악한다.
이를 통해 세션 간 연속성이 보장되며, 긴 대화에서도 핵심 정보가 유실되지 않는다.
