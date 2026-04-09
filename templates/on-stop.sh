#!/bin/bash
# Claude Code Stop hook — 세션 종료 시 메모리 로그 기록
# clbg에 의해 자동 생성됨

MEMORY_DIR="{memory_dir}"
TIMESTAMP=$(date +%Y-%m-%d_%H:%M:%S)
SESSION_LOG="$MEMORY_DIR/session-log.md"

# session-log.md가 없으면 생성
if [ ! -f "$SESSION_LOG" ]; then
  echo "# 세션 로그" > "$SESSION_LOG"
  echo "" >> "$SESSION_LOG"
fi

echo "- $TIMESTAMP — 세션 종료" >> "$SESSION_LOG"
