#!/bin/bash
# Live feed of files Claude Code creates or edits, for a terminal split pane.
# Usage: watch-writes.sh [folder]   (optional folder filter; default shows every session)
# Reads the JSONL log written by hooks/log-file-writes.sh.
# Paths print as plain file:// URLs: Ghostty opens visible URLs on Cmd+click,
# but ignores OSC 8 hidden links in ordinary shell output.

LOG="${CLAUDE_WRITE_LOG:-$HOME/.claude/logs/file_writes.jsonl}"
FILTER="${1:-}"
[[ -n "$FILTER" ]] && FILTER="$(cd "$FILTER" 2>/dev/null && pwd)"

echo "Watching Claude writes${FILTER:+ under ${FILTER/#$HOME/~}}  (Ctrl+C to stop)"
tail -n 300 -F "$LOG" 2>/dev/null \
  | jq --unbuffered -r 'def clean: tostring | explode | map(select((. >= 32 and . < 127) or . > 159)) | implode; [.timestamp[11:19], .tool, .file] | map(clean) | join("\u001f")' 2>/dev/null \
  | while IFS=$'\x1f' read -r ts tool file; do
    [[ -z "$file" ]] && continue
    [[ -n "$FILTER" && "$file" != "$FILTER"* ]] && continue
    case "$tool" in
        Write) mark=$'\033[32m+ new \033[0m' ;;
        Edit)  mark=$'\033[33m~ edit\033[0m' ;;
        *)     mark="  $tool" ;;
    esac
    url="file://$(printf '%s' "$file" | sed -e 's/%/%25/g' -e 's/ /%20/g' -e 's/#/%23/g' -e 's/?/%3F/g')"
    printf '\033[2m%s\033[0m %s %s\n' "$ts" "$mark" "$url"
done
