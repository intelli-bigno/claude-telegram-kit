# Troubleshooting

Every failure mode we hit while building this kit, with the symptoms you
see from Telegram and the diagnostic commands that confirm the cause.

If you hit something not covered here, please open an issue with the
error signature — PRs adding entries are the most useful contribution.

---

## 1. MCP is running but messages are silently dropped

**Symptom.** You DM the bot, nothing happens. No reaction, no reply, no
"typing…". The plugin's bun process is running (you can see it in
`ps aux`). Network connections to `api.telegram.org` are established.
Everything *looks* fine.

**Diagnosis.** Check the MCP log for the session in question:

```bash
# bg session (if you're using clbg)
ls -t ~/Library/Caches/claude-cli-nodejs/-Users-*--claude-bg/mcp-logs-plugin-telegram-telegram/*.jsonl \
  | head -1 \
  | xargs tail -3

# default $HOME session
ls -t ~/Library/Caches/claude-cli-nodejs/-Users-*/mcp-logs-plugin-telegram-telegram/*.jsonl \
  | head -1 \
  | xargs tail -3
```

Look for this line:

```json
{"debug":"Channel notifications skipped: server plugin:telegram:telegram not in --channels list for this session"}
```

If you see `registered` instead of `skipped`, this isn't your problem —
skip to the next section.

**Cause.** The Claude Code session was launched without the `--channels`
flag. The plugin starts normally, the MCP server starts normally, and the
bun process polls Telegram normally. But when the server calls
`mcp.notification({ method: 'notifications/claude/channel', ... })`,
Claude Code checks its internal subscription list, doesn't find the
plugin, and silently discards the notification.

**Fix.** Always launch Claude Code with:

```
claude --channels plugin:telegram@claude-plugins-official
```

`clbg` bakes this in. If you launched `claude` manually inside the tmux
session instead of using `clbg start`, this is why.

---

## 2. Background session freezes on a permission prompt

**Symptom.** The bg session answered the first one or two Telegram
messages fine, then stopped. Subsequent messages get the ack reaction
(👀) but no reply. `clbg attach` shows Claude is stuck on a dialog:

```
Do you want to proceed?
❯ 1. Yes
  2. Yes, and don't ask again for: ...
  3. No
```

**Diagnosis.**

```bash
tmux capture-pane -t claude-bg:0 -p | tail -20
```

If you see that dialog, this is it. The MCP log will show incoming
messages stacking up with no corresponding `reply` tool call:

```
"notifications/claude/channel: <message>"
"notifications/claude/channel: <next message>"
"notifications/claude/channel: <another>"
# ...no "Calling MCP tool: reply" in between
```

**Cause.** Claude wanted to run a shell command that wasn't on its
permission allowlist, so it's waiting for interactive approval. In a
detached tmux session, nothing is pressing 1.

**Fix (short-term).** Reattach and press 1 (or preferably 2 for
"don't ask again") — the backlog of messages starts processing.

**Fix (correct).** Launch with `--dangerously-skip-permissions` so
every tool call auto-approves. This is what `clbg` does. See
[`SECURITY.md`](SECURITY.md) for why this is safe when you have a
strict allowlist, and dangerous when you don't.

---

## 3. Background session "continues" a conversation that was never about Telegram

**Symptom.** You restart the bg session with `clbg restart`. You DM
the bot, and Claude's reply references code, files, or project names
you haven't mentioned all day. It feels like you're talking to someone
else's Claude.

**Diagnosis.**

```bash
tmux capture-pane -t claude-bg:0 -p | grep '~/'
```

The status bar at the bottom shows the cwd. If it shows `~` (your
`$HOME`), this is your problem. If it shows `~/.claude-bg`, something
else is wrong.

Another check — look at the session jsonl the bg is actually using:

```bash
ls -lat ~/.claude/projects/-Users-*/*.jsonl 2>/dev/null | head -5
# the most recently modified one is the one bg grabbed via --continue
```

Then dump the first ~20 messages:

```bash
head -20 <the_file>.jsonl | jq -r '.type, .message.content' 2>/dev/null
```

If those messages have nothing to do with Telegram or your current
context, that confirms the hijack.

**Cause.** `claude --continue` picks the most-recently-modified
`*.jsonl` in the cwd's session pool. The pool for `$HOME` is
`~/.claude/projects/-Users-<you>/`, which accumulates every Claude Code
session ever launched from `$HOME` (cron jobs, other terminals, IDE
sessions, random one-off questions, etc.). When `clbg restart` fires,
whichever session was modified most recently — including a completely
unrelated one — gets resumed.

We hit this exactly: a restart grabbed a session about "analyze the
global claude code config" and started answering Telegram messages with
that session's context.

**Fix.** Launch the bg session with a dedicated cwd that nothing else
uses:

```bash
mkdir -p ~/.claude-bg
# clbg sets WORK_DIR=~/.claude-bg by default — verify:
grep WORK_DIR scripts/claude-bg.sh
```

The isolated pool `~/.claude/projects/-Users-<you>--claude-bg/` will
only ever contain the bg session's own history, so `--continue` can't
get it wrong.

After applying the fix, **the next `clbg start` will be a fresh
session** — the old hijacked one lives in the other pool and can be
ignored or deleted.

---

## 4. First launch hangs on "Yes, I trust this folder?"

**Symptom.** You run `clbg start`, `clbg attach`, and see:

```
Accessing workspace: /Users/<you>/.claude-bg
Quick safety check: Is this a project you created or one you trust?
❯ 1. Yes, I trust this folder
  2. No, exit
```

**Cause.** Claude Code asks for folder trust once per directory. The
first time you launch it from a new cwd, you have to press Enter on
"Yes". `--dangerously-skip-permissions` doesn't bypass this particular
prompt — it's about workspace trust, not tool permissions, and the
two are intentionally separate.

**Fix.** Press Enter on "Yes, I trust this folder", wait a few seconds
for the plugins to load, then detach with `Ctrl+B D`. You only ever do
this once per cwd — the trust is remembered across restarts.

If you're getting re-prompted every restart, Claude Code's trust cache
may be broken. Check `~/Library/Application Support/claude-code/` (or
your platform's equivalent) for a trust-related file, but usually this
is a one-and-done thing.

---

## 5. Typing indicator disappears after 5 seconds

**Symptom.** You DM the bot. The 👀 reaction appears, "typing…" briefly
shows in the chat header, then disappears. Claude is still working in
the background; 30 seconds later the reply lands. You spent those 30
seconds wondering if Claude crashed.

**Cause.** Telegram's `sendChatAction('typing')` only persists ~5
seconds. The upstream plugin calls it exactly once on message receipt
and never again. Anything that takes longer than 5 seconds to answer
looks dead.

**Fix.** Apply `patches/telegram-typing-indicator.patch`. It adds a
4.5-second refresh loop that keeps the indicator alive until `reply` is
called (with a 30-minute hard cap as a safety net — we originally
tried 5 minutes and it was too aggressive for long-running thinks).

```bash
PLUGIN_DIR="$HOME/.claude/plugins/cache/claude-plugins-official/telegram/0.0.4"
cp "$PLUGIN_DIR/server.ts" "$PLUGIN_DIR/server.ts.orig"
patch -d "$PLUGIN_DIR" -p0 < patches/telegram-typing-indicator.patch
```

Restart the bg session (`clbg restart`) so the bun process reloads the
patched `server.ts`.

**Verification.** DM the bot a question that takes >10 seconds to
answer. The chat header should show "typing…" continuously until the
reply arrives.

---

## 6. Two Claude sessions fighting over the same bot

**Symptom.** Messages get ack'd (👀 appears) but replies come back
randomly, or not at all, or the reply references context from a
different conversation. You're running two `claude` sessions on the
same machine, both with the Telegram plugin loaded.

**Diagnosis.**

```bash
ps aux | grep "bun server.ts" | grep -v grep
# if you see more than one, this is your problem
```

Confirm both are connected to Telegram:

```bash
for pid in $(pgrep -f "bun server.ts"); do
  echo "=== $pid ==="
  lsof -a -p $pid -i -P 2>/dev/null | grep "149.154"
done
```

Check each session's MCP log for retries:

```bash
grep "409 Conflict" ~/Library/Caches/claude-cli-nodejs/*/mcp-logs-plugin-telegram-telegram/*.jsonl 2>/dev/null
```

If you see 409 messages, those are the losers in the polling race.

**Cause.** The Telegram Bot API only allows one `getUpdates` long-poll
client per bot token. Two clients means they trade the lock back and
forth unpredictably. Messages arrive at whichever is holding the lock
at that moment.

**Fix — short term.** Kill all but one of the bun processes:

```bash
# identify the one you want to keep (probably the clbg session)
# kill the others:
kill -TERM <pid>
```

Claude Code may respawn the killed one. If it does, you need to exit
the offending Claude Code session entirely, or launch it without the
plugin's channel registration (drop the `--channels` flag from that
session — the plugin will still start but won't actively compete on
the polling lock... no, actually it still polls regardless).

**Fix — correct.** Run the "other" session with its own bot via
`TELEGRAM_STATE_DIR`. See [`MULTI-BOT.md`](MULTI-BOT.md). This is the
only way to have two reliable Claude-on-Telegram sessions on one
machine.

---

## 7. ACK reaction appears but Claude never replies

**Symptom.** Every message gets the 👀 reaction — so the server is
clearly receiving and acking. But no reply ever comes, even after
minutes.

**Diagnosis.** This is almost always one of:

- Cause #1 (skipped channel registration): check the MCP log for
  `Channel notifications skipped`
- Cause #2 (permission prompt): `tmux capture-pane -t claude-bg:0 -p`
- Cause #6 (polling race): the *other* session is the one Claude Code
  is listening on

To tell which, check whether the message made it to Claude by reading
the MCP log for the target session:

```bash
ls -t ~/Library/Caches/claude-cli-nodejs/-Users-*--claude-bg/mcp-logs-plugin-telegram-telegram/*.jsonl \
  | head -1 \
  | xargs tail
```

- No `notifications/claude/channel: <your message>` → the message
  never reached this session (cause #6 — it went to another session
  that's polling the same bot)
- Has the notification but no subsequent `Calling MCP tool: reply` →
  Claude received it but can't respond (cause #2 — stuck on permission
  prompt) or is still thinking

---

## 8. Folder trust re-prompted after `clbg restart`

**Symptom.** You pressed Enter on "Yes, I trust this folder" during the
initial setup, detached, everything worked. Later you run
`clbg restart` and it asks again.

**Cause.** If `clbg restart` kills the session ungracefully, Claude
Code may not get a chance to persist its trust state. Or you're using
`--continue` against a session pool that was created before the trust
was saved.

**Fix.** Press Enter again. It should only happen once more. If it
keeps happening on every restart, something is actively clearing the
trust cache — worth investigating but extremely rare.

---

## 9. "Channel notifications registered" in logs but messages still not arriving

**Symptom.** The MCP log clearly shows:

```json
{"debug":"Channel notifications registered","sessionId":"..."}
```

And yet DMs to the bot produce nothing — no ack, no reply.

**Diagnosis.** Check if any `notifications/claude/channel:` entries
appear in that log file:

```bash
grep "notifications/claude/channel:" <log_file>
```

If the file has `Channel notifications registered` but zero
`notifications/claude/channel:` entries, the plugin isn't receiving
messages at all. Check:

```bash
# Is the bot token correct?
cat ~/.claude/channels/telegram/.env

# Is the polling process alive?
ps aux | grep "bun server.ts" | grep -v grep

# Is it connected to Telegram?
lsof -a -p <bun_pid> -i -P | grep "149.154"

# Check stderr output — telegram channel errors land there
# (Claude Code captures stderr into the MCP log, so search the log for telegram channel:)
grep "telegram channel:" <log_file>
```

Common issues at this stage:
- Invalid/revoked bot token → `Unauthorized` error in logs
- Network issue → no ESTABLISHED connections to `149.154.*`
- Sender not in `allowFrom` and `dmPolicy` is `allowlist` → message is
  silently dropped at the gate. Check `access.json` and ensure your
  Telegram user ID is in `allowFrom`.

---

## Diagnostic toolkit (copy-paste)

Quick sanity check:

```bash
# 1. tmux session alive?
tmux has-session -t claude-bg && echo "tmux OK" || echo "tmux MISSING"

# 2. bun process alive?
pgrep -lf "bun server.ts" || echo "no bun server"

# 3. connected to Telegram?
for pid in $(pgrep -f "bun server.ts"); do
  lsof -a -p $pid -i -P 2>/dev/null | grep 149.154 | head -1
done

# 4. latest MCP log
ls -t ~/Library/Caches/claude-cli-nodejs/-Users-*--claude-bg/mcp-logs-plugin-telegram-telegram/*.jsonl 2>/dev/null | head -1

# 5. channel registration status
grep -l "Channel notifications registered" \
  ~/Library/Caches/claude-cli-nodejs/*/mcp-logs-plugin-telegram-telegram/*.jsonl 2>/dev/null \
  | head

# 6. current bg screen
tmux capture-pane -t claude-bg:0 -p 2>/dev/null | tail -20

# 7. access.json sanity
jq '.dmPolicy, (.allowFrom | length)' ~/.claude/channels/telegram/access.json
```
