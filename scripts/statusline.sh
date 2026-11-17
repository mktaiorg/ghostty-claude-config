#!/bin/bash
# Claude Code status line
#   Line 1: project (git repo + branch, or folder) | folder | model + effort | context tokens
#   Line 2: session cost | elapsed time | lines +/- | 5-hour and 7-day usage limits | prompt cache state
#   Line 3: files this session created or edited, newest first (Cmd+click opens in VS Code)
#
# Context colors: yellow at CTX_WARN_TOKENS, red at CTX_STOP_TOKENS (override with env vars).
# Compatible with macOS /bin/bash 3.2. Requires jq.

CTX_WARN_TOKENS="${CTX_WARN_TOKENS:-300000}"
CTX_STOP_TOKENS="${CTX_STOP_TOKENS:-500000}"
MAX_FILES="${STATUSLINE_MAX_FILES:-4}"

input=$(cat)

# One jq call; fields joined with the ASCII unit separator so empty values survive `read`.
IFS=$'\x1f' read -r cwd model effort tokens ctx_size cost dur_ms added removed \
    five_pct five_reset seven_pct cache_warm cache_ttl agent_name transcript <<<"$(echo "$input" | jq -r '
  [ (.workspace.current_dir // .cwd // ""),
    (.model.display_name // ""),
    (.effort.level // ""),
    (.context_window.total_input_tokens // "" | tostring),
    (.context_window.context_window_size // "" | tostring),
    (.cost.total_cost_usd // "" | tostring),
    (.cost.total_duration_ms // "" | tostring),
    (.cost.total_lines_added // 0 | tostring),
    (.cost.total_lines_removed // 0 | tostring),
    (.rate_limits.five_hour.used_percentage // "" | tostring),
    (.rate_limits.five_hour.resets_at // "" | tostring),
    (.rate_limits.seven_day.used_percentage // "" | tostring),
    (.prompt_cache.warm // "" | tostring),
    (.prompt_cache.ttl // ""),
    (.agent.name // ""),
    (.transcript_path // "")
  ] | join("\u001f")' 2>/dev/null)"

[[ -z "$cwd" ]] && cwd="$PWD"

DIM=$'\033[2m'; RST=$'\033[0m'; YEL=$'\033[33m'; RED=$'\033[31m'; GRN=$'\033[32m'
SEP=" ${DIM}|${RST} "

# Color a percentage: yellow >= 70, red >= 90.
pct_color() {
    local p=${1%.*}
    if (( p >= 90 )); then printf '%s' "$RED"; elif (( p >= 70 )); then printf '%s' "$YEL"; fi
}

# --- Folder display: ~ for home; keep first two and last segment when long ---
cwd_display="${cwd/#$HOME/~}"
IFS='/' read -ra parts <<<"$cwd_display"
n=${#parts[@]}
if (( n > 4 )); then
    cwd_display="${parts[0]}/${parts[1]}/.../${parts[$((n-1))]}"
fi

# --- Project segment: git repo + branch, else folder ---
if branch=$(git -C "$cwd" branch --show-current 2>/dev/null); then
    repo=$(basename "$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)")
    project_part="📁 $repo ${DIM}(${branch:-detached})${RST}"
else
    project_part="📁 $cwd_display"
    cwd_display=""
fi

# --- Model + effort ---
model_part=""
if [[ -n "$model" ]]; then
    model_part="$model"
    [[ -n "$effort" ]] && model_part="$model_part ${DIM}${effort}${RST}"
fi
[[ -n "$agent_name" ]] && model_part="$model_part ${DIM}[${agent_name}]${RST}"

# --- Context tokens (absolute, not percent) ---
ctx_part=""
if [[ -n "$tokens" && "$tokens" != "0" ]]; then
    color=""
    (( tokens >= CTX_WARN_TOKENS )) && color="$YEL"
    (( tokens >= CTX_STOP_TOKENS )) && color="$RED"
    ctx_part="${color}ctx $(( tokens / 1000 ))K"
    if [[ -n "$ctx_size" && "$ctx_size" != "0" ]]; then
        if (( ctx_size >= 1000000 )); then ctx_part="$ctx_part/$(( ctx_size / 1000000 ))M"
        else ctx_part="$ctx_part/$(( ctx_size / 1000 ))K"; fi
    fi
    (( tokens >= CTX_STOP_TOKENS )) && ctx_part="$ctx_part handoff now"
    (( tokens >= CTX_WARN_TOKENS && tokens < CTX_STOP_TOKENS )) && ctx_part="$ctx_part wrap up"
    ctx_part="$ctx_part${RST}"
fi

line1="$project_part"
[[ -n "$cwd_display" ]] && line1="$line1$SEP$cwd_display"
[[ -n "$model_part" ]] && line1="$line1$SEP$model_part"
[[ -n "$ctx_part" ]] && line1="$line1$SEP$ctx_part"

# --- Line 2: cost, time, lines, limits, cache ---
l2=()
[[ -n "$cost" ]] && l2+=("$(printf '$%.2f' "$cost")")
if [[ -n "$dur_ms" ]]; then
    m=$(( ${dur_ms%.*} / 60000 ))
    if (( m >= 60 )); then l2+=("$(( m / 60 ))h$(( m % 60 ))m"); else l2+=("${m}m"); fi
fi
if [[ "$added" != "0" || "$removed" != "0" ]]; then
    l2+=("${GRN}+${added}${RST} ${RED}-${removed}${RST}")
fi
if [[ -n "$five_pct" ]]; then
    seg="$(pct_color "$five_pct")5h $(printf '%.0f' "$five_pct")%${RST}"
    if [[ -n "$five_reset" ]]; then
        seg="$seg ${DIM}resets $(date -r "${five_reset%.*}" '+%-I:%M%p' 2>/dev/null | tr 'APM' 'apm')${RST}"
    fi
    l2+=("$seg")
fi
[[ -n "$seven_pct" ]] && l2+=("$(pct_color "$seven_pct")7d $(printf '%.0f' "$seven_pct")%${RST}")
if [[ "$cache_warm" == "true" ]]; then
    l2+=("${DIM}cache warm ${cache_ttl}${RST}")
elif [[ "$cache_warm" == "false" ]]; then
    l2+=("${YEL}cache cold${RST}")
fi

line2=""
for s in "${l2[@]}"; do
    if [[ -z "$line2" ]]; then line2="$s"; else line2="$line2$SEP$s"; fi
done

# --- Line 3: files edited this session, as OSC 8 links ---
# Claude Code renders OSC 8 links in the status line, so Cmd+click opens the file in VS Code.
line3=""
if [[ -f "$transcript" ]]; then
    files=$(grep -E '"name":"(Edit|Write|NotebookEdit)"' "$transcript" 2>/dev/null \
        | jq -r '.message.content[]? | select(.type=="tool_use" and (.name=="Edit" or .name=="Write" or .name=="NotebookEdit")) | .input.file_path // .input.notebook_path // empty' 2>/dev/null \
        | awk '{a[NR]=$0} END {for (i=NR; i>=1; i--) if (!seen[a[i]]++) print a[i]}')
    if [[ -n "$files" ]]; then
        total=$(printf '%s\n' "$files" | wc -l | tr -d ' ')
        shown=0
        while IFS= read -r f; do
            (( shown >= MAX_FILES )) && break
            url="vscode://file$(printf '%s' "$f" | sed -e 's/%/%25/g' -e 's/ /%20/g' -e 's/#/%23/g' -e 's/?/%3F/g')"
            link=$'\033]8;;'"$url"$'\033\\'"$(basename "$f")"$'\033]8;;\033\\'
            if [[ -z "$line3" ]]; then line3="$link"; else line3="$line3  $link"; fi
            shown=$((shown + 1))
        done <<<"$files"
        (( total > MAX_FILES )) && line3="$line3  ${DIM}+$((total - MAX_FILES)) more${RST}"
        line3="${DIM}edited${RST} $line3"
    fi
fi

echo "$line1"
[[ -n "$line2" ]] && echo "$line2"
[[ -n "$line3" ]] && echo "$line3"
exit 0
