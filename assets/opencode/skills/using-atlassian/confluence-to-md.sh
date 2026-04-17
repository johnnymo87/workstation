#!/usr/bin/env bash
# Fetch a Confluence page and convert to clean GFM markdown.
# Usage: confluence-to-md.sh <page_id> [output_file]
#
# Requires: curl, jq, python3, pandoc
# Environment: ATLASSIAN_EMAIL, ATLASSIAN_API_TOKEN, ATLASSIAN_SITE
set -euo pipefail

page_id="${1:?Usage: confluence-to-md.sh <page_id> [output_file]}"
output="${2:-/dev/stdout}"

curl -sf -u "$ATLASSIAN_EMAIL:$ATLASSIAN_API_TOKEN" \
  "https://$ATLASSIAN_SITE/wiki/api/v2/pages/$page_id?body-format=view" \
  | jq -r '.body.view.value' \
  | python3 -c "
import sys, re
html = sys.stdin.read()
# Strip Confluence code-panel wrapper divs (preserves inner <pre>)
html = re.sub(r'<div class=\"code panel[^\"]*\"[^>]*>\s*<div class=\"codeContent[^\"]*\">\s*', '', html)
html = re.sub(r'\s*</div>\s*</div>', '', html)
# Strip table-wrap divs
html = re.sub(r'<div class=\"table-wrap\">', '', html)
# Strip <a> tags, keep inner text (raw URLs for smart links)
html = re.sub(r'<a\s[^>]*>(.*?)</a>', r'\1', html, flags=re.DOTALL)
print(html)
" \
  | pandoc -f html -t gfm --wrap=none 2>/dev/null \
  | sed 's/``` syntaxhighlighter-pre/```/' \
  > "$output"
