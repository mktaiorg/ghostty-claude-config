#!/bin/bash
# Claude Code PostToolUse hook: append one JSON line per Edit/Write/NotebookEdit.
# Feeds scripts/watch-writes.sh. Requires jq.

LOG="${CLAUDE_WRITE_LOG:-$HOME/.claude/logs/file_writes.jsonl}"
mkdir -p "$(dirname "$LOG")"

jq -c --arg ts "$(date '+%Y-%m-%dT%H:%M:%S')" \
  '{timestamp: $ts, tool: .tool_name, file: (.tool_input.file_path // .tool_input.notebook_path // "unknown")}' \
  >> "$LOG" 2>/dev/null

exit 0
