#!/bin/bash

# Read JSON input from stdin
input=$(cat)

# Extract basic information
model=$(echo "$input" | jq -r '.model.display_name')
current_dir=$(echo "$input" | jq -r '.workspace.current_dir')

# WORKAROUND: After /compact, Claude Code may pass stale transcript_path
# Use PPID-based mailbox from SessionStart hook as authoritative source
stdin_path=$(echo "$input" | jq -r '.transcript_path')
ppid="${PPID:-unknown}"
mailbox="${HOME}/.claude/runtime/${ppid}/transcript_path"

transcript_path="$stdin_path"
if [[ -f "$mailbox" ]]; then
  new_path="$(<"$mailbox")"
  if [[ -n "$new_path" && -f "$new_path" ]]; then
    transcript_path="$new_path"
  fi
fi

# Display directory with ~ for home
display_dir="${current_dir/#$HOME/~}"

# Git branch
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'N/A')

# Context tracking - CC triggers /compact at ~78% of 200k tokens
CONTEXT_LIMIT=156000

# Parse transcript file for latest token usage
context_tokens=0
if [ -f "$transcript_path" ]; then
    # Get the most recent usage data (tac reads file backwards)
    last_usage=$(tac "$transcript_path" | grep -m 1 '"type":"assistant"' | jq '.message.usage // empty' 2>/dev/null)

    if [ -n "$last_usage" ]; then
        input_tokens=$(echo "$last_usage" | jq -r '.input_tokens // 0')
        cache_creation=$(echo "$last_usage" | jq -r '.cache_creation_input_tokens // 0')
        cache_read=$(echo "$last_usage" | jq -r '.cache_read_input_tokens // 0')
        output_tokens=$(echo "$last_usage" | jq -r '.output_tokens // 0')

        context_tokens=$((input_tokens + cache_creation + cache_read + output_tokens))
    fi
fi

# Calculate percentage and create progress bar
context_pct=$(awk "BEGIN {printf \"%.1f\", ($context_tokens / $CONTEXT_LIMIT) * 100}")
bar_length=20
filled=$(awk "BEGIN {printf \"%.0f\", ($context_tokens / $CONTEXT_LIMIT) * $bar_length}")
filled=$((filled > bar_length ? bar_length : filled))
bar=$(printf '█%.0s' $(seq 1 $filled))$(printf '░%.0s' $(seq 1 $((bar_length - filled))))

# Color based on usage
if (( $(echo "$context_pct < 50" | bc -l) )); then
    color="\033[92m"  # Green
elif (( $(echo "$context_pct < 80" | bc -l) )); then
    color="\033[93m"  # Yellow
elif (( $(echo "$context_pct < 90" | bc -l) )); then
    color="\033[38;5;208m"  # Orange
else
    color="\033[91m"  # Red
fi
reset="\033[0m"

context_info=" | [${color}${bar}${reset}] ${color}${context_pct}%${reset} ($(printf "%'d" $context_tokens))"

# Base status line
base_status="🤖 $model | 📁 $display_dir | 🌿 $branch${context_info}"

# Try to get ccusage information
cost_info=""
if command -v npx >/dev/null 2>&1; then
    # Get costs from JSON API - per directory and per day
    today=$(date +%Y%m%d)

    # ccusage uses path-based session IDs: convert /Users/foo.bar/baz -> -Users-foo-bar-baz
    ccusage_session_id=$(echo "$current_dir" | sed 's/^\//-/' | tr '/.' '--')

    # Fetch daily costs with instance breakdown
    daily_json=$(npx -y ccusage daily --instances --since "$today" --json 2>/dev/null)

    dir_cost=""
    daily_cost=""
    if [ -n "$daily_json" ]; then
        # Get cost for this specific directory/instance from .projects[sessionId]
        if [ -n "$ccusage_session_id" ]; then
            dir_cost=$(echo "$daily_json" | jq -r --arg sid "$ccusage_session_id" '(.projects[$sid] // [])[0].totalCost // empty' 2>/dev/null)
            if [ -n "$dir_cost" ] && [ "$dir_cost" != "null" ]; then
                dir_cost="\$$(printf "%.2f" "$dir_cost")"
            else
                dir_cost=""
            fi
        fi

        # Get total cost for today (all directories) from .totals
        daily_cost=$(echo "$daily_json" | jq -r '.totals.totalCost // empty' 2>/dev/null)
        if [ -n "$daily_cost" ] && [ "$daily_cost" != "null" ]; then
            daily_cost="\$$(printf "%.2f" "$daily_cost")"
        else
            daily_cost=""
        fi
    fi

    # Build cost information string
    cost_parts=()
    if [ -n "$dir_cost" ]; then
        cost_parts+=("📁 $dir_cost")
    fi
    if [ -n "$daily_cost" ]; then
        cost_parts+=("📅 $daily_cost")
    fi

    # Join cost parts with " | "
    if [ ${#cost_parts[@]} -gt 0 ]; then
        cost_info=" | "
        for i in "${!cost_parts[@]}"; do
            if [ $i -gt 0 ]; then
                cost_info="${cost_info} | "
            fi
            cost_info="${cost_info}${cost_parts[$i]}"
        done
    fi
fi

# Output the complete status line
echo -e "${base_status}${cost_info}"
