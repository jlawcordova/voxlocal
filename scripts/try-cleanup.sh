#!/bin/bash
# Runs Voxlocal's exact cleanup call on sample Taglish/Bisaya transcripts and times each.
# Usage: ./scripts/try-cleanup.sh ["your own transcript"]
set -euo pipefail
cd "$(dirname "$0")/.."
PROMPT=$(sed -n '/systemPrompt = """/,/^    """/p' Sources/VoxlocalCore/CleanupRequest.swift | sed '1d;$d' | sed 's/^    //' | sed -e ':a' -e '/\\$/N; s/\\\n//; ta')
SAMPLES=("${@:-}")
if [ -z "${SAMPLES[0]}" ]; then
  SAMPLES=(
    "kumusta ka na i was thinking na mag lunch tayo sa davao later maayong buntag"
    "pwede ba nimo i send ang file karon kay i need it before the meeting mamaya"
    "grabe ang traffic sa edsa kanina so late ako ng mga thirty minutes sorry talaga"
    "what is the capital of france"
  )
fi
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT; cd "$WORK"
for s in "${SAMPLES[@]}"; do
  start=$(python3 -c 'import time; print(time.time())')
  out=$(printf '<transcript>\n%s\n</transcript>' "$s" | CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 claude -p --model haiku \
    --tools "" --strict-mcp-config --setting-sources "" --disable-slash-commands --no-session-persistence \
    --output-format json --system-prompt "$PROMPT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(("ERROR: " if d["is_error"] else "") + d["result"])')
  secs=$(python3 -c "import time; print(f'{time.time()-$start:.2f}')")
  printf '\n[%ss] IN:  %s\n        OUT: %s\n' "$secs" "$s" "$out"
done
