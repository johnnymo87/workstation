#!/bin/bash

# Read JSON input from stdin
input=$(cat)

# Extract basic information
# Handle model as either object with display_name or plain string
model=$(echo "$input" | jq -r 'if .model | type == "object" then .model.display_name else .model end // ""')
# Handle current_dir from workspace object or cwd field
current_dir=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')

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

# Extract session cost from Claude Code stdin (instant, no external calls)
session_cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')
cost_info=""
if [ -n "$session_cost" ] && [ "$session_cost" != "null" ]; then
    formatted_cost=$(printf "%.2f" "$session_cost")
    cost_info=" | 💰 \$${formatted_cost}"
fi

# Output the complete status line
echo -e "${base_status}${cost_info}"
