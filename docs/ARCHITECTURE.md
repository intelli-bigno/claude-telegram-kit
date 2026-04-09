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

## 자동 재시작 (Auto-restart)

`clbg start` 및 `clbg resume`는 기본적으로 bare `claude` 대신 **wrapper 스크립트**를
tmux 안에서 실행합니다. wrapper는 다음을 처리합니다:

### 동작 원리

1. **세션 resume**: wrapper가 시작되면 `~/.claude.json`에서 `lastSessionId`를 읽고,
   해당 세션의 jsonl 파일이 존재하면 `--resume`으로 이어서 실행합니다. jsonl이 없거나
   `lastSessionId`가 없으면 새 UUID로 fresh session을 시작합니다.

2. **자동 재시작 루프**: Claude Code 프로세스가 종료되면(OOM, 네트워크 오류, idle
   타임아웃 등) wrapper가 자동으로 다시 시작합니다. 이전 세션의 컨텍스트가 resume을
   통해 유지됩니다.

3. **Crash loop 감지**: 매 종료 시 RETRIES 카운터가 증가하며, 5분 이상
   실행 후 종료된 경우에만 카운터가 리셋됩니다. 20회 초과 시 300초 백오프
   후 카운터를 리셋합니다. 재시작 간격은 `5 * min(retries, 5)` 초로
   점진적으로 증가합니다.

4. **토큰 활성화/비활성화**: wrapper 시작 시 `.env`에 실제 봇 토큰을 기록하고,
   wrapper 종료 시(루프 탈출, SIGTERM, SIGINT) `.env`를 `DISABLED`로 변경합니다.
   이를 통해 wrapper가 죽은 상태에서 다른 프로세스가 같은 토큰으로 polling하는
   충돌을 방지합니다.

### 파일 위치

```
~/.claude-bg/<label>/
├── run.sh          ← _generate_wrapper()가 자동 생성 (직접 편집 금지)
└── restart.log     ← 재시작 이벤트 로그
```

### 일회성 실행 (--no-restart)

`--no-restart` 플래그를 사용하면 wrapper 없이 bare `claude`를 직접 실행합니다.
디버깅이나 단발성 테스트에 유용합니다:

```bash
clbg start mybot --bg --no-restart    # wrapper 없이 일회성 실행
clbg start mybot --bg                 # 기본: auto-restart wrapper 사용
```

---

## 메모리 자동 저장 (Memory Auto-save)

세션이 종료될 때 자동으로 기록을 남기는 메커니즘입니다.

### 동작 원리

1. **Stop hook 트리거**: Claude Code의 Stop hook이 세션 종료 시 자동으로
   `on-stop.sh`를 실행합니다. 이 스크립트는 `clbg new`가 컨테이너 cwd를
   scaffold할 때 `templates/on-stop.sh` 템플릿으로부터 생성됩니다.

2. **session-log.md 기록**: `on-stop.sh`는 `memory/session-log.md`에 종료
   시각을 append합니다. 시간이 지나면 이 파일이 세션 히스토리 타임라인이 됩니다.

3. **CLAUDE.md 유도**: 컨테이너의 CLAUDE.md에 "중요한 결정이나 맥락은 세션 종료
   전에 memory/에 저장해주세요"라는 지시를 포함시켜, Claude가 사전에 중요 맥락을
   memory/ 디렉토리에 마크다운 파일로 저장하도록 유도합니다.

### 한계

- **crash 시 미실행**: Stop hook은 Claude Code가 정상적으로 종료될 때만
  실행됩니다. OOM kill, SIGKILL, 네트워크 단절 등으로 프로세스가 비정상
  종료되면 hook이 트리거되지 않습니다.
- **기록 범위**: on-stop.sh는 종료 시각만 기록합니다. 세션 중 어떤 작업을
  했는지는 Claude가 CLAUDE.md 지시에 따라 memory/에 직접 남겨야 합니다.

### 파일 위치

```
~/.claude-bg/<label>/
├── .claude/
│   └── settings.json    ← Stop hook 설정 (hooks-settings.json 템플릿 기반)
├── on-stop.sh           ← Stop hook 스크립트 (on-stop.sh 템플릿 기반)
└── memory/
    └── session-log.md   ← 세션 종료 시각 로그 (자동 생성)
```

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
