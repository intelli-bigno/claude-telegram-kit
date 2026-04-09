#!/usr/bin/env python3
"""
clbg — Claude Code Telegram Background runner, v2.

Manages multiple Claude Code sessions, each bound to its own Telegram bot
and running persistently in tmux. Every container has:

  - a dedicated cwd under ~/.claude-bg/<label>/
  - a dedicated Telegram state dir ~/.claude/channels/telegram-<label>/
  - a tmux session: claude-bg-<label>
  - an entry in ~/.claude-bg/containers.json (our metadata)
  - an entry in ~/.claude.json projects (Claude Code's state hub)

The third point is why this tool works where v1 kept tripping: by pre-seeding
the Claude Code project state (hasTrustDialogAccepted, hasCompletedProjectOnboarding,
hasTrustDialogHooksAccepted), we never get ambushed by one-shot dialogs in a
detached tmux session.

Commands:
  clbg new <label> [--notes STR]     create a fresh container (no bot token yet)
  clbg link <label> <token>          attach a bot token to a container's state
  clbg start <label> [--bg]          start a fresh Claude session (new UUID)
  clbg resume <label> [--bg]         resume the container's last session by ID
  clbg restart <label> [--bg]        stop + resume
  clbg attach <label>                tmux attach to the container
  clbg stop <label>                  kill the tmux session (cl still persisted)
  clbg list                          show all containers and their state
  clbg status <label>                detailed status for one container
  clbg rm <label>                    permanently delete a container
  clbg exec <label> <prompt>         run a one-shot prompt via `claude -p`

Flags:
  --bg    with start/resume/restart: create tmux detached instead of attaching
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

# ----- paths and constants ---------------------------------------------------

HOME = Path.home()
CLAUDE_JSON = HOME / ".claude.json"
BG_ROOT = HOME / ".claude-bg"
CONTAINERS_JSON = BG_ROOT / "containers.json"
CHANNELS_ROOT = HOME / ".claude" / "channels"
CLAUDE_BIN = HOME / ".claude" / "local" / "claude"
PROJECTS_ROOT = HOME / ".claude" / "projects"
PLUGIN_CHANNEL = "plugin:telegram@claude-plugins-official"

# Base args for interactive bg claude. --channels makes the plugin deliver
# messages, --dangerously-skip-permissions lets us run unattended (allowlist
# is the real security boundary, see kit docs).
BASE_CLAUDE_ARGS = [
    "--channels",
    PLUGIN_CHANNEL,
    "--dangerously-skip-permissions",
]

LABEL_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9_-]*$")

# ANSI color helpers for `list` output
def _c(code: str, s: str) -> str:
    if not sys.stdout.isatty():
        return s
    return f"\033[{code}m{s}\033[0m"


def green(s: str) -> str: return _c("32", s)
def red(s: str) -> str: return _c("31", s)
def yellow(s: str) -> str: return _c("33", s)
def dim(s: str) -> str: return _c("2", s)
def bold(s: str) -> str: return _c("1", s)


# ----- json helpers (atomic, with backup) ------------------------------------

def load_json(path: Path) -> dict:
    if not path.exists():
        return {}
    with open(path, "r") as f:
        return json.load(f)


def save_json_atomic(path: Path, data: dict, mode: int = 0o600) -> None:
    """Write JSON atomically via temp file + rename. Preserves file permissions."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.chmod(tmp, mode)
    tmp.replace(path)


def load_containers() -> dict:
    if not CONTAINERS_JSON.exists():
        return {"version": 1, "containers": {}}
    return load_json(CONTAINERS_JSON)


def save_containers(data: dict) -> None:
    save_json_atomic(CONTAINERS_JSON, data, mode=0o600)


def with_claude_json_lock(mutator) -> None:
    """
    Read ~/.claude.json, call mutator(data) in place, write it back atomically.
    Creates a .bak on first touch each invocation for safety.

    Claude Code may also write to this file concurrently; we accept last-write-wins
    semantics because the fields we mutate (projects[<our cwd>].hasTrust* etc.)
    don't overlap with fields Claude Code writes during normal operation.
    """
    if not CLAUDE_JSON.exists():
        raise FileNotFoundError(
            f"{CLAUDE_JSON} doesn't exist — is Claude Code installed and has it ever been run?"
        )
    # one-time backup per clbg invocation
    backup = CLAUDE_JSON.with_suffix(".json.clbg.bak")
    if not backup.exists():
        shutil.copy2(CLAUDE_JSON, backup)
    data = load_json(CLAUDE_JSON)
    mutator(data)
    save_json_atomic(CLAUDE_JSON, data, mode=0o644)  # claude owns this; match its mode


# ----- container metadata ----------------------------------------------------

def container_cwd(label: str) -> Path:
    return BG_ROOT / label


def container_state_dir(label: str) -> Path:
    return CHANNELS_ROOT / f"telegram-{label}"


def container_tmux_name(label: str) -> str:
    return f"claude-bg-{label}"


def validate_label(label: str) -> None:
    if not LABEL_RE.match(label):
        die(f"invalid label '{label}'. Use alphanumeric + underscore/dash, starting with a letter/digit.")


def get_container(label: str) -> dict:
    data = load_containers()
    if label not in data.get("containers", {}):
        die(f"no container '{label}'. List with: clbg list")
    return data["containers"][label]


def die(msg: str, code: int = 1) -> None:
    print(red(f"error: {msg}"), file=sys.stderr)
    sys.exit(code)


def info(msg: str) -> None:
    print(f"[clbg] {msg}")


# ----- trust injection into ~/.claude.json ----------------------------------

def inject_trust(cwd: Path) -> None:
    """
    Pre-seed the Claude Code project state for this cwd so none of the first-run
    dialogs (folder trust, hooks trust, project onboarding) ever fire. This is
    the trick that keeps detached tmux sessions from hanging.
    """
    def mutate(data: dict) -> None:
        projects = data.setdefault("projects", {})
        entry = projects.setdefault(str(cwd), {})
        # required shape — mirrors what Claude Code writes itself
        entry.setdefault("allowedTools", [])
        entry.setdefault("mcpContextUris", [])
        entry.setdefault("mcpServers", {})
        entry.setdefault("enabledMcpjsonServers", [])
        entry.setdefault("disabledMcpjsonServers", [])
        # trust flags — all three must be true to avoid any prompt
        entry["hasTrustDialogAccepted"] = True
        entry["hasTrustDialogHooksAccepted"] = True
        entry["hasCompletedProjectOnboarding"] = True
        entry.setdefault("projectOnboardingSeenCount", 1)
        entry.setdefault("hasClaudeMdExternalIncludesApproved", False)
        entry.setdefault("hasClaudeMdExternalIncludesWarningShown", False)
    with_claude_json_lock(mutate)


def remove_claude_json_entry(cwd: Path) -> None:
    def mutate(data: dict) -> None:
        projects = data.get("projects", {})
        projects.pop(str(cwd), None)
    with_claude_json_lock(mutate)


def read_claude_json_project(cwd: Path) -> dict:
    data = load_json(CLAUDE_JSON)
    return data.get("projects", {}).get(str(cwd), {})


# ----- state dir scaffolding -------------------------------------------------

INITIAL_ACCESS_JSON = {
    "dmPolicy": "allowlist",
    "allowFrom": [],
    "groups": {},
    "pending": {},
    "ackReaction": "👀",
}

INITIAL_ENV_TEMPLATE = "TELEGRAM_BOT_TOKEN=DISABLED\n"

def scaffold_state_dir(state_dir: Path) -> None:
    state_dir.mkdir(parents=True, exist_ok=True)
    (state_dir / "approved").mkdir(exist_ok=True)
    os.chmod(state_dir, 0o700)

    env_path = state_dir / ".env"
    if not env_path.exists():
        env_path.write_text(INITIAL_ENV_TEMPLATE)
    os.chmod(env_path, 0o600)

    access_path = state_dir / "access.json"
    if not access_path.exists():
        save_json_atomic(access_path, INITIAL_ACCESS_JSON, mode=0o600)


def scaffold_cwd(cwd: Path) -> None:
    cwd.mkdir(parents=True, exist_ok=True)
    marker = cwd / "README.md"
    if not marker.exists():
        marker.write_text(
            f"# clbg container cwd\n\n"
            f"This directory is the dedicated cwd for a `clbg` container.\n"
            f"Managed by ~/dotfiles/claude/scripts/claude-bg.sh (v2).\n"
            f"Do not store real work here — the container claude may run with\n"
            f"--dangerously-skip-permissions.\n"
        )


# ----- tmux wrappers ---------------------------------------------------------

def tmux_has(session: str) -> bool:
    r = subprocess.run(
        ["tmux", "has-session", "-t", session],
        capture_output=True,
    )
    return r.returncode == 0


def tmux_kill(session: str) -> None:
    subprocess.run(["tmux", "kill-session", "-t", session], capture_output=True)


def tmux_new_session(
    session: str,
    cwd: Path,
    cmd: list[str],
    env: dict[str, str],
    detached: bool,
) -> None:
    """Start a new tmux session running cmd in cwd with merged env."""
    full_env = {**os.environ, **env}
    shell_cmd = " ".join(_shell_escape(c) for c in cmd)
    args = ["tmux", "new-session"]
    if detached:
        args += ["-d"]
    args += ["-s", session, "-c", str(cwd), shell_cmd]
    subprocess.run(args, env=full_env, check=True)


def tmux_attach(session: str) -> None:
    os.execvp("tmux", ["tmux", "attach", "-t", session])


def _shell_escape(s: str) -> str:
    # minimal single-quote escaping for shell
    if not s or any(c in s for c in " '\"$\\`"):
        return "'" + s.replace("'", "'\"'\"'") + "'"
    return s


# ----- sessions-index.json reader (for richer status) ------------------------

def read_sessions_index(cwd: Path) -> list[dict]:
    encoded = str(cwd).replace("/", "-")
    idx_path = PROJECTS_ROOT / encoded / "sessions-index.json"
    if not idx_path.exists():
        return []
    try:
        data = load_json(idx_path)
        return data.get("entries", [])
    except Exception:
        return []


# ----- commands --------------------------------------------------------------

def cmd_new(args) -> None:
    label = args.label
    validate_label(label)

    data = load_containers()
    containers = data.setdefault("containers", {})
    if label in containers:
        die(f"container '{label}' already exists. Use 'clbg rm {label}' first if you want to recreate.")

    cwd = container_cwd(label)
    state_dir = container_state_dir(label)
    tmux_name = container_tmux_name(label)

    info(f"scaffolding cwd: {cwd}")
    scaffold_cwd(cwd)

    info(f"scaffolding state dir: {state_dir}")
    scaffold_state_dir(state_dir)

    info(f"injecting trust into ~/.claude.json for {cwd}")
    inject_trust(cwd)

    containers[label] = {
        "createdAt": datetime.now(timezone.utc).isoformat(),
        "botUsername": None,
        "stateDir": str(state_dir),
        "cwd": str(cwd),
        "tmuxSession": tmux_name,
        "notes": args.notes or "",
    }
    save_containers(data)
    info(f"registered in containers.json")

    print()
    print(bold("Next steps:"))
    print(f"  1. Open @BotFather on Telegram, send /newbot, create a new bot")
    print(f"  2. Copy the token (looks like 123456789:AAH...)")
    print(f"  3. Link it to this container:")
    print(f"       {bold(f'clbg link {label} <token>')}")
    print(f"  4. Bootstrap allowlist — temporarily flip to pairing mode, DM your")
    print(f"     new bot, pair, then flip back to allowlist:")
    print(f"       {dim('# Claude session pointed at this container:')}")
    print(f"       {bold(f'clbg exec {label} /telegram:access policy pairing')}")
    print(f"       {dim('# (DM your new bot to get a pairing code)')}")
    print(f"       {bold(f'clbg exec {label} /telegram:access pair <code>')}")
    print(f"       {bold(f'clbg exec {label} /telegram:access policy allowlist')}")
    print(f"  5. Start the background session:")
    print(f"       {bold(f'clbg start {label}')}")


def cmd_link(args) -> None:
    label = args.label
    validate_label(label)
    token = args.token.strip()
    if not re.match(r"^\d{6,}:[A-Za-z0-9_-]{30,}$", token):
        die("token doesn't look like a valid Telegram bot token (expected '123456789:AA...')")

    c = get_container(label)

    # 세션이 실행 중이면 .env 덮어쓰기를 스킵 (containers.json만 업데이트)
    tmux_name = c["tmuxSession"]
    session_running = tmux_has(tmux_name)

    # containers.json에 botToken과 botUsername 저장 (한 번의 load/save 블록)
    data = load_containers()
    data["containers"][label]["botToken"] = token
    bot_username = _try_fetch_bot_username(token)
    if bot_username:
        data["containers"][label]["botUsername"] = bot_username
    save_containers(data)
    info(f"saved token to containers.json")
    if bot_username:
        info(f"bot username: @{bot_username}")
    else:
        info("couldn't fetch bot username (offline? network error?) — will show as '?'")

    if session_running:
        print(yellow(f"세션이 실행 중이므로 .env는 변경하지 않았습니다."))
        print(yellow(f"clbg restart {label}로 적용하세요."))
    else:
        state_dir = Path(c["stateDir"])
        env_path = state_dir / ".env"
        env_path.write_text(f"TELEGRAM_BOT_TOKEN={token}\n")
        os.chmod(env_path, 0o600)
        info(f"wrote token to {env_path}")

    print()
    print(bold("Linked. Next:"))
    print(f"  {bold(f'clbg start {label}')}    {dim('# start the bg session')}")


def _try_fetch_bot_username(token: str) -> Optional[str]:
    import urllib.request, urllib.error
    try:
        with urllib.request.urlopen(
            f"https://api.telegram.org/bot{token}/getMe", timeout=5
        ) as r:
            body = json.loads(r.read())
        if body.get("ok"):
            return body["result"]["username"]
    except Exception:
        return None
    return None


def _build_claude_cmd(extra: list[str]) -> list[str]:
    return [str(CLAUDE_BIN), *BASE_CLAUDE_ARGS, *extra]


def _container_env(c: dict) -> dict[str, str]:
    return {"TELEGRAM_STATE_DIR": c["stateDir"]}


# ----- token isolation helpers -----------------------------------------------

def activate_token(label: str) -> None:
    """containers.json에서 botToken을 읽어 state dir의 .env에 기록한다.
    동일 botToken을 가진 다른 컨테이너의 .env가 실제 토큰 상태이면
    먼저 DISABLED로 교체하여 crash/재부팅 후에도 토큰 중복을 방지한다."""
    data = load_containers()
    c = data["containers"][label]
    token = c.get("botToken")
    if not token:
        die(f"container '{label}'에 botToken이 없습니다. 먼저 clbg link {label} <token>을 실행하세요.")
    if not re.match(r"^\d{6,}:[A-Za-z0-9_-]{30,}$", token):
        die(f"container '{label}'의 botToken이 유효하지 않습니다. clbg link {label} <token>으로 재설정하세요.")
    # 동일 토큰을 가진 다른 컨테이너의 .env를 DISABLED로 교체
    for other_label, other_c in data.get("containers", {}).items():
        if other_label == label:
            continue
        if other_c.get("botToken") == token:
            other_env = Path(other_c["stateDir"]) / ".env"
            if other_env.exists():
                env_content = other_env.read_text()
                if any(line.startswith("TELEGRAM_BOT_TOKEN=") and line.split("=", 1)[1].strip() == token
                       for line in env_content.splitlines()):
                    other_env.write_text("TELEGRAM_BOT_TOKEN=DISABLED\n")
                    os.chmod(other_env, 0o600)
                    info(f"deactivated stale token in container '{other_label}'")
    env_path = Path(c["stateDir"]) / ".env"
    env_path.write_text(f"TELEGRAM_BOT_TOKEN={token}\n")
    os.chmod(env_path, 0o600)


def deactivate_token(label: str) -> None:
    """state dir의 .env를 DISABLED로 교체한다."""
    data = load_containers()
    c = data["containers"].get(label)
    if not c:
        return  # 이미 삭제된 컨테이너는 무시
    env_path = Path(c["stateDir"]) / ".env"
    env_path.write_text("TELEGRAM_BOT_TOKEN=DISABLED\n")
    os.chmod(env_path, 0o600)


def _require_token(c: dict, label: str) -> None:
    """토큰이 사용 가능한 상태인지 확인한다. .env의 DISABLED 값도 '토큰 없음'으로 처리."""
    # containers.json의 botToken 필드 확인
    data = load_containers()
    container = data.get("containers", {}).get(label, {})
    stored_token = container.get("botToken")
    if stored_token:
        return  # containers.json에 토큰이 저장되어 있으면 OK (start 시 activate_token이 .env에 기록)
    # containers.json에 없으면 .env 확인 (하위 호환)
    env_path = Path(c["stateDir"]) / ".env"
    if not env_path.exists():
        die(f"no bot token in {env_path}. Run: clbg link {label} <token>")
    content = env_path.read_text()
    for line in content.splitlines():
        stripped = line.split("=", 1)[1].strip() if "=" in line else ""
        if line.startswith("TELEGRAM_BOT_TOKEN=") and stripped and stripped != "DISABLED":
            return
    die(f"no bot token configured. Run: clbg link {label} <token>")


def _do_start_session(label: str, session_args: list[str], args) -> None:
    """cmd_start와 cmd_resume 공용 내부 함수.
    activate_token을 한 번만 호출하고 tmux 세션을 시작한다."""
    c = get_container(label)
    tmux_name = c["tmuxSession"]

    activate_token(label)
    info(f"activated token for {label}")

    cmd = _build_claude_cmd(session_args)
    flags = [a for a in session_args if a.startswith("--")]
    info(f"launching tmux '{tmux_name}' with flags: {flags}")
    tmux_new_session(tmux_name, Path(c["cwd"]), cmd, _container_env(c), detached=args.bg)
    if args.bg:
        print(f"started detached. Attach: clbg attach {label}")
    else:
        tmux_attach(tmux_name)


def cmd_start(args) -> None:
    label = args.label
    validate_label(label)
    c = get_container(label)
    _require_token(c, label)

    tmux_name = c["tmuxSession"]
    if tmux_has(tmux_name):
        die(f"tmux session '{tmux_name}' already running. Use: clbg attach {label}")

    new_uuid = str(uuid.uuid4())
    info(f"starting fresh session {new_uuid}")
    _do_start_session(label, ["--session-id", new_uuid], args)


def cmd_resume(args) -> None:
    label = args.label
    validate_label(label)
    c = get_container(label)
    _require_token(c, label)

    tmux_name = c["tmuxSession"]
    if tmux_has(tmux_name):
        die(f"tmux session '{tmux_name}' already running. Use: clbg attach {label}")

    project = read_claude_json_project(Path(c["cwd"]))
    last_id = project.get("lastSessionId")
    if not last_id:
        info("no prior session found — starting fresh instead")
        new_uuid = str(uuid.uuid4())
        _do_start_session(label, ["--session-id", new_uuid], args)
        return

    # verify jsonl exists before calling --resume (avoids a hard fail)
    encoded = str(Path(c["cwd"])).replace("/", "-")
    jsonl = PROJECTS_ROOT / encoded / f"{last_id}.jsonl"
    if not jsonl.exists():
        info(f"last session {last_id} jsonl missing — starting fresh instead")
        new_uuid = str(uuid.uuid4())
        _do_start_session(label, ["--session-id", new_uuid], args)
        return

    info(f"resuming session {last_id}")
    _do_start_session(label, ["--resume", last_id], args)


def cmd_restart(args) -> None:
    label = args.label
    validate_label(label)
    c = get_container(label)
    _require_token(c, label)
    tmux_name = c["tmuxSession"]
    if tmux_has(tmux_name):
        info(f"stopping {tmux_name}")
        tmux_kill(tmux_name)
        time.sleep(0.5)
    # tmux 유무와 관계없이 항상 토큰 비활성화 (crash 후 .env에 토큰이 남아있을 수 있음)
    deactivate_token(label)
    info(f"deactivated token for {label}")
    cmd_resume(args)


def cmd_stop(args) -> None:
    label = args.label
    validate_label(label)
    c = get_container(label)
    tmux_name = c["tmuxSession"]
    if not tmux_has(tmux_name):
        info(f"{tmux_name} not running")
        return
    tmux_kill(tmux_name)
    info(f"{tmux_name} stopped")
    # 토큰 비활성화 — 다른 세션에서 동일 토큰으로 polling 경쟁 방지
    deactivate_token(label)
    info(f"deactivated token for {label}")


def cmd_attach(args) -> None:
    label = args.label
    validate_label(label)
    c = get_container(label)
    tmux_name = c["tmuxSession"]
    if not tmux_has(tmux_name):
        die(f"{tmux_name} not running. Start with: clbg start {label}")
    tmux_attach(tmux_name)


def cmd_exec(args) -> None:
    label = args.label
    validate_label(label)
    c = get_container(label)
    _require_token(c, label)
    prompt = args.prompt

    cmd = [
        str(CLAUDE_BIN),
        *BASE_CLAUDE_ARGS,
        "-p",
        prompt,
    ]
    env = {**os.environ, **_container_env(c)}
    subprocess.run(cmd, cwd=c["cwd"], env=env)


def _fmt_cost(cost: Any) -> str:
    try:
        return f"${float(cost):.2f}"
    except Exception:
        return "-"


def _fmt_tokens(n: Any) -> str:
    try:
        n = int(n)
    except Exception:
        return "-"
    if n >= 1_000_000: return f"{n/1_000_000:.1f}M"
    if n >= 1_000: return f"{n/1_000:.1f}K"
    return str(n)


def cmd_list(args) -> None:
    data = load_containers()
    containers = data.get("containers", {})
    if not containers:
        print(dim("no containers yet. Create one: clbg new <label>"))
        return

    rows = []
    for label in sorted(containers.keys()):
        c = containers[label]
        tmux_name = c["tmuxSession"]
        running = tmux_has(tmux_name)
        project = read_claude_json_project(Path(c["cwd"]))
        last_id = project.get("lastSessionId") or ""
        last_id_short = last_id[:8] + "…" if last_id else "-"
        cost = _fmt_cost(project.get("lastCost"))
        total_in = project.get("lastTotalInputTokens", 0) or 0
        total_out = project.get("lastTotalOutputTokens", 0) or 0
        cache_read = project.get("lastTotalCacheReadInputTokens", 0) or 0
        tokens = _fmt_tokens(int(total_in) + int(total_out) + int(cache_read))
        bot = c.get("botUsername") or "-"
        bot_display = f"@{bot}" if bot != "-" else "-"
        status = green("running") if running else dim("stopped")
        rows.append([label, bot_display, status, last_id_short, cost, tokens, c.get("notes") or ""])

    # compute column widths
    headers = ["LABEL", "BOT", "STATUS", "LAST SESSION", "COST", "TOKENS", "NOTES"]
    cols = list(zip(*([headers] + rows)))
    widths = [max(_visible_len(str(x)) for x in col) for col in cols]

    def row_to_line(r):
        return "  ".join(_pad(str(c), w) for c, w in zip(r, widths))

    print(bold(row_to_line(headers)))
    for r in rows:
        print(row_to_line(r))


def _visible_len(s: str) -> int:
    # strip ANSI color for width calc
    return len(re.sub(r"\033\[[0-9;]*m", "", s))


def _pad(s: str, w: int) -> str:
    return s + " " * max(0, w - _visible_len(s))


def cmd_status(args) -> None:
    label = args.label
    validate_label(label)
    c = get_container(label)
    tmux_name = c["tmuxSession"]
    cwd = Path(c["cwd"])
    state_dir = Path(c["stateDir"])
    running = tmux_has(tmux_name)
    project = read_claude_json_project(cwd)

    print(bold(f"container: {label}"))
    print(f"  created:       {c.get('createdAt', '?')}")
    print(f"  notes:         {c.get('notes') or '-'}")
    print(f"  bot:           @{c.get('botUsername') or '-'}")
    print(f"  state dir:     {state_dir}")
    print(f"  cwd:           {cwd}")
    print(f"  tmux session:  {tmux_name}  ({green('running') if running else dim('stopped')})")
    print()
    print(bold("claude state (from ~/.claude.json):"))
    for k in ("lastSessionId", "lastCost", "lastDuration", "lastTotalInputTokens",
              "lastTotalOutputTokens", "lastTotalCacheReadInputTokens"):
        if k in project:
            print(f"  {k:35} {project[k]}")
    lmu = project.get("lastModelUsage")
    if lmu:
        print(f"  {'lastModelUsage (models)':35} {', '.join(lmu.keys())}")

    entries = read_sessions_index(cwd)
    if entries:
        print()
        print(bold(f"sessions-index.json ({len(entries)} entries):"))
        for e in entries[-5:]:
            sid = e.get("sessionId", "?")[:8]
            fp = (e.get("firstPrompt") or "").strip().replace("\n", " ")[:60]
            summary = (e.get("summary") or "").strip().replace("\n", " ")[:60]
            mc = e.get("messageCount", "?")
            print(f"  {sid}…  msgs={mc}  {fp!r}")
            if summary:
                print(f"    {dim('→ ' + summary)}")


def cmd_rm(args) -> None:
    label = args.label
    validate_label(label)
    c = get_container(label)
    tmux_name = c["tmuxSession"]
    cwd = Path(c["cwd"])
    state_dir = Path(c["stateDir"])

    if not args.yes:
        print(yellow(f"about to DELETE container '{label}':"))
        print(f"  - tmux session:  {tmux_name}")
        print(f"  - cwd:           {cwd}")
        print(f"  - state dir:     {state_dir}")
        print(f"  - .claude.json entry")
        print(f"  - containers.json entry")
        resp = input(f"type the label '{label}' to confirm: ").strip()
        if resp != label:
            die("aborted")

    if tmux_has(tmux_name):
        info(f"killing {tmux_name}")
        tmux_kill(tmux_name)

    # 삭제 전 .env 토큰 비활성화
    deactivate_token(label)
    info(f"deactivated token for {label}")

    if state_dir.exists():
        info(f"removing {state_dir}")
        shutil.rmtree(state_dir)

    if cwd.exists():
        info(f"removing {cwd}")
        shutil.rmtree(cwd)

    info("removing .claude.json projects entry")
    remove_claude_json_entry(cwd)

    data = load_containers()
    data["containers"].pop(label, None)
    save_containers(data)
    info(f"removed container '{label}'")


# ----- main ------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="clbg",
        description="Claude Code Telegram Background runner (v2)",
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    def _label_arg(sp):
        sp.add_argument("label", help="container label (alphanumeric, -_)")

    def _bg_flag(sp):
        sp.add_argument("--bg", action="store_true",
                        help="start tmux detached instead of attaching")

    sp = sub.add_parser("new", help="create a new container")
    _label_arg(sp)
    sp.add_argument("--notes", help="free-form description")
    sp.set_defaults(func=cmd_new)

    sp = sub.add_parser("link", help="link a bot token to an existing container")
    _label_arg(sp)
    sp.add_argument("token", help="Telegram bot token from BotFather")
    sp.set_defaults(func=cmd_link)

    sp = sub.add_parser("start", help="start a fresh claude session for a container")
    _label_arg(sp); _bg_flag(sp)
    sp.set_defaults(func=cmd_start)

    sp = sub.add_parser("resume", help="resume the container's last session by ID")
    _label_arg(sp); _bg_flag(sp)
    sp.set_defaults(func=cmd_resume)

    sp = sub.add_parser("restart", help="stop + resume")
    _label_arg(sp); _bg_flag(sp)
    sp.set_defaults(func=cmd_restart)

    sp = sub.add_parser("stop", help="kill the container's tmux session")
    _label_arg(sp)
    sp.set_defaults(func=cmd_stop)

    sp = sub.add_parser("attach", help="tmux attach to a container")
    _label_arg(sp)
    sp.set_defaults(func=cmd_attach)

    sp = sub.add_parser("list", help="list all containers", aliases=["ls"])
    sp.set_defaults(func=cmd_list)

    sp = sub.add_parser("status", help="detailed status for one container")
    _label_arg(sp)
    sp.set_defaults(func=cmd_status)

    sp = sub.add_parser("rm", help="permanently delete a container")
    _label_arg(sp)
    sp.add_argument("-y", "--yes", action="store_true", help="skip confirmation")
    sp.set_defaults(func=cmd_rm)

    sp = sub.add_parser("exec", help="run a one-shot prompt via 'claude -p'")
    _label_arg(sp)
    sp.add_argument("prompt", nargs=argparse.REMAINDER, help="prompt to send")
    sp.set_defaults(func=lambda a: cmd_exec(_coerce_exec_args(a)))

    return p


def _coerce_exec_args(a):
    # prompt is REMAINDER so it comes as a list of tokens
    a.prompt = " ".join(a.prompt)
    return a


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    if not hasattr(args, "func"):
        parser.print_help()
        sys.exit(1)
    try:
        args.func(args)
    except KeyboardInterrupt:
        print()
        sys.exit(130)


if __name__ == "__main__":
    main()
