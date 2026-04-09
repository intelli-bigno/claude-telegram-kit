# Security

This kit runs Claude Code in the background with
`--dangerously-skip-permissions`, which means **every shell command Claude
wants to run gets auto-approved**. That's necessary for a detached tmux
session (nobody is there to press "yes" on permission prompts), but it
shifts the entire security boundary to the allowlist. Read this doc
before going live.

## Threat model

The question you should be able to answer is:

> If my bot token leaks, what can an attacker do?

Without this kit (plain interactive Claude Code): they can send the bot
messages. Claude Code will pop permission prompts for every dangerous
action, and you'll see them and refuse. Damage is limited to what Claude
does autonomously.

With this kit (background runner, `--dangerously-skip-permissions`): if
the attacker is **also in the allowlist**, they can execute arbitrary
shell commands on your machine as your user. That's a full remote code
execution vulnerability.

If they're **not in the allowlist**, the server drops their message at
the gate and nothing happens. The allowlist is the entire defense.

## What the allowlist actually does

`~/.claude/channels/telegram/access.json`:

```json
{
  "dmPolicy": "allowlist",
  "allowFrom": ["<your Telegram user ID>"],
  "groups": {},
  "pending": {},
  "ackReaction": "👀"
}
```

- `dmPolicy: "allowlist"` — DMs from anyone not in `allowFrom` are
  dropped silently at the server. They don't reach Claude at all.
- `dmPolicy: "pairing"` (default for official plugin) — first-time DMs
  trigger a pairing flow where the bot DMs back a code. You have to
  confirm the code inside Claude Code. This is safer for setup but
  slower and still allows attackers to initiate pairings (they're just
  not completed).
- `dmPolicy: "disabled"` — bot ignores all DMs. Useful for temporary
  lockdown.

The server code that enforces this is in `server.ts`, specifically the
`gate()` function. Non-allowlisted senders are rejected before
`handleInbound()` runs, so their messages never become Claude tool
inputs. This is a real gate, not obfuscation.

**For a background runner with `--dangerously-skip-permissions`, always
use `dmPolicy: "allowlist"`.** Never leave it on `pairing` — an attacker
who gets the token can DM the bot and initiate a pairing, and if you
glance at the notification and casually approve, you've just given them
shell access.

## Protecting the token

### containers.json의 botToken 필드

`clbg link`는 토큰을 `.env`뿐만 아니라 `~/.claude-bg/containers.json`의
`botToken` 필드에도 저장한다. 이 필드는 `clbg start`/`clbg resume` 시
`.env`에 실제 토큰을 기록하고, `clbg stop` 시 `DISABLED`로 교체하는
토큰 격리 메커니즘의 핵심이다.

`containers.json`은 모드 0600으로 생성되며, 토큰이 평문으로 저장된다.
따라서 `.env`와 동일한 보안 수준으로 취급해야 한다:

- **절대 git에 커밋하지 않는다** — `.gitignore`에 이미 포함되어 있지만
  `~/.claude-bg/` 경로 자체가 프로젝트 외부에 있으므로 실수할 가능성은 낮다.
- **다른 사용자에게 읽기 권한을 주지 않는다** — `ls -la ~/.claude-bg/containers.json`
  으로 0600인지 확인한다.
- **토큰 갱신 시 `clbg link`를 다시 실행한다** — `.env`와 `containers.json`
  양쪽이 동시에 업데이트된다.

### .env 파일

`~/.claude/channels/telegram/.env` has mode 0600 by default (owner
read/write only), created by the official plugin. Verify:

```bash
ls -la ~/.claude/channels/telegram/.env
# should show: -rw------- 1 <you> <group>
```

If it's anything else (644, 755, world-readable), fix it:

```bash
chmod 600 ~/.claude/channels/telegram/.env
```

**Never commit the token**. This kit's `.gitignore` excludes `.env` and
`access.json`, but double-check before any `git add`.

**Never paste the token into a chat or issue tracker**, including to
Claude. Generate a fresh one via BotFather if you suspect it's leaked
(`/revoke` in BotFather, then paste the new one into `.env`).

## Revoking a compromised token

1. DM @BotFather, select your bot, run `/revoke` — this invalidates the
   token immediately.
2. Ask BotFather for a new token via the same menu.
3. Update `~/.claude/channels/telegram/.env` (or wherever you point
   `TELEGRAM_STATE_DIR`).
4. Restart the bg session so the plugin reloads the new token:
   ```bash
   clbg restart
   ```
5. Verify via a test DM that the bot still responds.

The old token is dead the moment you run `/revoke` — anyone polling with
the old token will get immediate `Unauthorized` errors. Anything running
in between step 1 and step 3 just fails; the token is never in a
half-valid state.

## Finding your Telegram user ID

You need your own numeric user ID to put in `allowFrom`. Several ways:

- **Easiest, while bootstrapping**: use the pairing flow. Set
  `dmPolicy: "pairing"`, DM your bot, the server's log records your
  user ID as it processes the pairing request. Or just run
  `/telegram:access pair <code>` and the skill adds you automatically.
- **Via a public bot**: DM `@userinfobot` or `@getmyid_bot` (neither
  is affiliated with this project — pick one you trust).
- **From your own bot's logs** after sending a first message (if
  you're OK temporarily allowing any sender): inspect
  `~/Library/Caches/claude-cli-nodejs/.../mcp-logs-plugin-telegram-telegram/*.jsonl`
  and look for `user_id` in the `notifications/claude/channel` entries.

## Multiple allowlisted senders

If you want to grant a colleague access:

1. Have them DM the bot so their user ID shows up (or they tell you
   their ID via another channel — remember, user IDs are not secret,
   they just act as authentication for the allowlist)
2. Add their ID to `allowFrom`:
   ```
   /telegram:access allow <their_user_id>
   ```
3. Verify:
   ```bash
   jq '.allowFrom' ~/.claude/channels/telegram/access.json
   ```

Remember that anyone in `allowFrom` can run arbitrary shell commands via
the bg session. **Only add people who have the same trust level as your
own account** — treat it like SSH access, not like a chat invite.

To revoke:

```
/telegram:access remove <user_id>
```

## Why `--dangerously-skip-permissions` and nothing less

Alternatives we considered and rejected:

- **Pre-populate `permissions.allow` in `settings.json`** — you'd have
  to anticipate every command Claude might ever run. First unknown
  command hangs the session. Brittle.
- **Launch a named pipe to simulate "press 1" input** — fragile, still
  doesn't give Claude per-prompt context, and leaves an obvious backdoor
  for anyone with shell access.
- **Monkey-patch Claude Code to auto-approve in detached mode** —
  unmaintained, breaks on every upgrade.
- **Use `dontAsk` permission mode** — `dontAsk` is for non-interactive
  runs that *reject* instead of prompting. Not the behavior we want
  (Claude would refuse to do anything useful).

`--dangerously-skip-permissions` is blunt but correct. The price is
that the allowlist is now load-bearing.

## What happens if the bg session is compromised

If an allowlisted attacker sends a malicious message and Claude follows
it to run `rm -rf ~/`, your files are gone. There's no undo. The
mitigations, in order of importance:

1. **Keep `allowFrom` tight.** Just you, or you plus a small handful of
   hand-vetted trusted people.
2. **Don't reuse the bot token in other projects.** If the token lives
   in one place, revoking is easy.
3. **Consider running the bg session inside a VM, container, or
   dedicated user account.** Especially if you're allowlisting more
   than yourself.
4. **Keep backups.** Time Machine, rsnapshot, whatever — the usual
   advice applies extra here.
5. **Review the transcript periodically.** Look for commands you don't
   remember asking for. The jsonl files under
   `~/.claude/projects/-Users-*--claude-bg/` are a full audit log.

## Plugin upstream security

This kit depends on `telegram@claude-plugins-official`, maintained by
Anthropic. We trust it at the same level we trust Claude Code itself.
If you have a security concern about the upstream plugin, report it
there — this kit can't compensate for vulnerabilities in the plugin.

The only modification we make is the typing indicator patch
(`patches/telegram-typing-indicator.patch`), which touches three
narrowly-scoped places in `server.ts`:

1. Two new `Map`s at module scope for tracking typing intervals
2. Two new functions (`startTyping`, `stopTyping`)
3. Call sites: one in the message handler, one in the `reply` tool
   handler

No new network code, no new file I/O, no new permissions surface. You
can audit the diff in `patches/telegram-typing-indicator.patch` in a
few minutes.

## tl;dr

- `dmPolicy: "allowlist"` is mandatory
- `allowFrom` contains only people you would trust with shell access
- Token file is 0600
- Token never committed to git
- Revoke immediately via BotFather `/revoke` if you suspect a leak
- Back up your files — the bg session can do anything your shell can
