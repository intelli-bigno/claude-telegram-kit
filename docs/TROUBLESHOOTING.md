# Troubleshooting

Every failure mode we hit while building this kit, with the symptoms you
see from Telegram and the diagnostic commands that confirm the cause.

If you hit something not covered here, please open an issue with the
error signature — PRs adding entries are the most valuable contribution.

---

## 1. MCP is running but messages are silently dropped

**Symptom.** You DM the bot, nothing happens. No reaction, no reply, no
"typing…". The plugin's bun process is running (you see it in `ps aux`).
Network connections to `api.telegram.org` are established. Everything
*looks* fine.

**Diagnosis.**

```bash
# bg container (if you're using clbg)
ls -t ~/Library/Caches/claude-cli-nodejs/-Users-*--claude-bg-<label>/mcp-logs-plugin-telegram-telegram/*.jsonl \
  | head -1 | xargs tail -3
```

Look for this line:

```json
{"debug":"Channel notifications skipped: server plugin:telegram:telegram not in --channels list for this session"}
```

If you see `registered` instead of `skipped`, this isn't your problem —
skip to the next section.

**Cause.** The Claude Code session was launched without the `--channels`
flag. The plugin starts normally, polls Telegram normally, receives
messages normally. But when the server calls
`mcp.notification({ method: 'notifications/claude/channel', ... })`,
Claude Code checks its subscription list, doesn't find the plugin, and
discards the notification.

**Fix.** `clbg` always passes `--channels` — if you see this, you're
launching `claude` manually inside the tmux session instead of via
`clbg start`. Use the script.

---

## 2. Background session freezes on a permission prompt

**Symptom.** The bg session answered a few Telegram messages fine, then
stopped. Subsequent messages get the 👀 ack but no reply.
`clbg attach <label>` shows Claude stuck on:

```
Do you want to proceed?
❯ 1. Yes
  2. Yes, and don't ask again for: ...
  3. No
```

**Diagnosis.**
```bash
tmux capture-pane -t claude-bg-<label>:0 -p | tail -20
```

MCP log shows messages stacking with no corresponding `reply` tool call:
```
"notifications/claude/channel: <message>"
"notifications/claude/channel: <next>"
# ...no "Calling MCP tool: reply" between them
```

**Cause.** Claude wanted to run a shell command not on its permission
allowlist, so it's waiting for interactive approval. Nothing presses 1 in
a detached session.

**Fix (immediate).** `clbg attach <label>`, press 2 ("don't ask again
for ..."), detach with `Ctrl+B D`. Backlog starts processing.

**Fix (correct).** `clbg start` / `resume` / `restart` already include
`--dangerously-skip-permissions`, so this shouldn't happen. If it does,
you're either running claude manually without the flag, or something in
the environment is overriding it — check `clbg status <label>` to confirm
the tmux session is what you think it is.

---

## 3. Background session "continues" a conversation that was never about Telegram

**Symptom.** You restart a container. You DM the bot. Claude's reply
references code, files, or project names you haven't mentioned all day.
Feels like you're talking to someone else's Claude.

**Diagnosis.**
```bash
tmux capture-pane -t claude-bg-<label>:0 -p | grep '~/'
```

The status bar at the bottom shows the cwd. If it shows `~` (your
`$HOME`), this is your problem. If it shows `~/.claude-bg/<label>`,
something else is wrong (keep reading this section for the v2-era
variant).

**Cause (v1, pre-container-model).** `claude --continue` picked the
most-recently-modified session from a shared cwd pool. The pool for
`$HOME` accumulates every Claude Code session ever launched there, so
"most recent" was often a completely unrelated session.

**Fix.** This doesn't happen with `clbg` v2 because:
1. Each container has its own isolated cwd (`~/.claude-bg/<label>/`), so
   its session pool only contains its own history
2. `clbg resume` never uses `--continue` — it reads `lastSessionId` from
   `~/.claude.json` and passes `--resume <uuid>` explicitly

If you're somehow still hitting this with `clbg`, check that
`clbg status <label>` shows the expected cwd and last session ID. If the
lastSessionId looks wrong, it was written by something else — another
Claude Code process sharing the same cwd (shouldn't happen unless you've
manually pointed two containers at the same directory).

---

## 4. First launch hangs on "Yes, I trust this folder?"

**Symptom.** First time you `clbg start <label>` a container, you see:
```
Quick safety check: Is this a project you created or one you trust?
❯ 1. Yes, I trust this folder
  2. No, exit
```

**Cause.** Something prevented `clbg new` from pre-injecting the trust
fields into `~/.claude.json`. This shouldn't happen in v2 — `clbg new`
writes `hasTrustDialogAccepted: true`, `hasTrustDialogHooksAccepted: true`,
and `hasCompletedProjectOnboarding: true` before the session ever starts.

**Diagnosis.**
```bash
python3 -c "
import json
d = json.load(open('$HOME/.claude.json'))
cwd = '$HOME/.claude-bg/<label>'  # replace <label>
p = d['projects'].get(cwd, {})
for k in ['hasTrustDialogAccepted','hasTrustDialogHooksAccepted','hasCompletedProjectOnboarding']:
    print(f'{k}: {p.get(k)}')
"
```

If any field is missing or false, `clbg new` didn't complete properly
(maybe an error you didn't notice, or you created the container manually).

**Fix.** Attach once and press Enter — Claude Code will flip the field to
true itself. Then detach and it'll stay fixed. Alternative: remove and
re-create the container:
```bash
clbg stop <label>
clbg rm <label> -y
clbg new <label>
clbg link <label> <token>
clbg start <label>
```

---

## 5. Typing indicator disappears mid-think

**Symptom.** You DM the bot. 👀 appears. "typing…" briefly shows in the
chat header, then disappears. Claude is still working; 30+ seconds later
the reply lands. You spent those seconds wondering if Claude crashed.

**Cause.** Telegram's `sendChatAction('typing')` only persists ~5 seconds.
The upstream plugin calls it exactly once on message receipt.

**Fix.** Apply `patches/telegram-typing-indicator.patch`. It adds a
4.5-second refresh loop that keeps the indicator alive until `reply` is
sent (30-minute hard cap as a runaway guard — we originally tried 5
minutes and it was way too aggressive for long-running thinks).

```bash
PLUGIN_DIR="$HOME/.claude/plugins/cache/claude-plugins-official/telegram/0.0.4"
cp "$PLUGIN_DIR/server.ts" "$PLUGIN_DIR/server.ts.orig"
patch -d "$PLUGIN_DIR" -p1 < patches/telegram-typing-indicator.patch
clbg restart <label>  # reload patched bun
```

**Verification.** DM the bot a question that takes >10 seconds to answer.
The chat header should show "typing…" continuously until the reply
arrives.

---

## 6. Multiple containers fighting over the same bot

**Symptom.** Messages get ack'd (👀 appears) but replies come back
randomly, or not at all, or reference context from a different
conversation. Multiple `clbg` containers are listed as running.

**Diagnosis.**
```bash
ps aux | grep "bun server.ts" | grep -v grep
# If more bun processes than running containers, something's off

# Check each bun's TELEGRAM_STATE_DIR
ps eww $(pgrep -f "bun server.ts") | grep -o "TELEGRAM_STATE_DIR=[^ ]*" | sort | uniq -c
# Expected: each state dir used by exactly one bun
```

If two bun processes share the same `TELEGRAM_STATE_DIR`, they're racing
on the same bot token. That's a misconfiguration — probably you manually
edited `containers.json` or reused a state dir across containers.

**Fix (immediate).** Kill the extras:
```bash
# Identify the one you want to keep (say, 99516):
kill -TERM <other pids>
```

**Fix (correct).** Make sure each container in `~/.claude-bg/containers.json`
has a unique `stateDir`. The default `clbg new <label>` creates
`~/.claude/channels/telegram-<label>/`, which is unique by label.

---

## 7. ACK reaction appears but Claude never replies

**Symptom.** Every message gets 👀. No reply, even after minutes. Typing
indicator doesn't persist.

**Diagnosis.** This is almost always one of:

- Cause #1 (channel registration skipped): check the MCP log for
  `Channel notifications skipped`
- Cause #2 (permission prompt): `tmux capture-pane`
- Cause #6 (polling race): the *other* session is holding the lock

Check MCP log for the target container:
```bash
ls -t ~/Library/Caches/claude-cli-nodejs/-Users-*--claude-bg-<label>/mcp-logs-plugin-telegram-telegram/*.jsonl \
  | head -1 | xargs tail
```

- No `notifications/claude/channel: <your message>` → message never
  reached this session (cause #6 — it went to another polling bun)
- Has the notification but no subsequent `Calling MCP tool: reply` →
  Claude received it but can't respond (cause #2 — stuck on permission
  prompt, or still thinking)

---

## 8. `clbg resume` complains about a missing jsonl

**Symptom.**
```bash
$ clbg resume main
[clbg] last session abc123 jsonl missing — starting fresh instead
```

**Cause.** `~/.claude.json` projects entry has a `lastSessionId` that no
longer has a jsonl file on disk. Usually because the jsonl was manually
moved, archived, or Claude Code cleaned it up.

**Fix.** None needed — `clbg resume` automatically falls back to
`clbg start` (fresh session) when the jsonl is missing. This is the
intended safety net.

If you didn't want a fresh start, check `/tmp/claude-bg-archive/` or
wherever you might have moved the jsonl, and restore it:
```bash
mv /tmp/claude-bg-archive/<uuid>.jsonl ~/.claude/projects/-Users-*--claude-bg-<label>/
clbg resume <label>
```

---

## 9. "Resume from summary vs full" prompt fires on restart

**Symptom.** `clbg restart <label>` attaches and you see:
```
This session is 7h 40m old and 284k tokens.
Resuming the full session will consume a substantial portion of your usage limits.
We recommend resuming from a summary.

❯ 1. Resume from summary (recommended)
  2. Resume full session as-is
  3. Don't ask me again
```

**Cause.** This prompt only fires when `claude --continue` is used
against a large old session. `clbg` v2 **should never hit this** because
it uses `--resume <exact UUID>`, not `--continue`.

If you see this, you're probably running `claude --continue` manually
inside the tmux session, or your `clbg` is somehow falling through to
`--continue`.

**Fix (immediate).** Select "1. Resume from summary" and the session
continues. Or select "3. Don't ask me again" to permanently dismiss for
this session in the future.

**Fix (correct).** Use `clbg` commands, not raw `claude`. Check your
shell history — `clbg restart <label>` should be the last command you
ran, not `claude --continue`.

---

## 10. Idle warning: "You've been away 2h..."

**Symptom.** Attaching to a bg session, you see:
```
You've been away 2h and this conversation is 28k tokens.
If this is a new task, clearing context will save usage and be faster.

❯ 1. Continue this conversation
  2. Send message as a new conversation
  3. Don't ask me again
```

**Cause.** Claude Code's idle warning — triggers after N minutes away with
a non-trivial session. This is a UI affordance, not an error.

**Fix.** Pick whichever option matches your intent. "Don't ask me again"
permanently dismisses for this container. The prompt doesn't block
incoming Telegram messages, but it does block your interactive attach
until you answer.

---

## Diagnostic toolkit (copy-paste)

Quick sanity check for a container:

```bash
label=main  # change to yours

# 1. Does the container exist?
clbg list | grep -w "$label"

# 2. Container details
clbg status "$label"

# 3. tmux session alive?
tmux has-session -t "claude-bg-$label" && echo "tmux OK" || echo "tmux MISSING"

# 4. bun process alive?
pgrep -lf "bun server.ts" || echo "no bun server"

# 5. Connected to Telegram?
for pid in $(pgrep -f "bun server.ts"); do
  conn=$(lsof -a -p $pid -i -P 2>/dev/null | grep 149.154 | head -1)
  echo "$pid: ${conn:-no telegram connection}"
done

# 6. Channel registration status for this container
ls -t ~/Library/Caches/claude-cli-nodejs/-Users-*--claude-bg-$label/mcp-logs-plugin-telegram-telegram/*.jsonl 2>/dev/null \
  | head -1 | xargs grep -H "registered\|skipped" 2>/dev/null

# 7. Current bg screen
tmux capture-pane -t "claude-bg-$label:0" -p 2>/dev/null | tail -20

# 8. Access.json sanity (count only, no IDs)
state=$(python3 -c "import json; print(json.load(open('$HOME/.claude-bg/containers.json'))['containers']['$label']['stateDir'])")
jq '{dmPolicy, allowFromCount: (.allowFrom|length)}' "$state/access.json"
```
