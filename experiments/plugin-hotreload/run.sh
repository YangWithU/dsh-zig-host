#!/usr/bin/env bash
# Hot reload: does editing a plugin's source change a RUNNING process's behaviour?
#
# Problem
#   The whole point of this project is that a plugin's source can be edited and
#   the host picks it up without restarting. Does it actually work end to end?
#
# Conclusion (verified 2026-09-27)
#   Yes. In ONE dsh_zig process, two consecutive bash-tool calls returned
#       '[exit 0]\nfirst\n'   then   '[EXIT 0]\nsecond\n'
#   The marker string was edited in src/plugins/tools.zig between the two turns
#   (t=25s), and '[hotreload] tools plugin reloaded' was printed before turn 2.
#
#   Two things had to be right:
#     1. The reload check must run AFTER reading input, not before. Placed before,
#        it blocks on stdin and an edit made while blocked is only noticed one
#        turn later -- i.e. "press enter after editing" still runs the old code.
#        This was observed first (both results were '[exit 0]') and then fixed.
#     2. The new build must land on a NEW path (zig-out/reload/<fingerprint>/).
#        Overwriting a loaded .so corrupts mapped code pages (SIGSEGV, measured
#        in experiments/dlopen-reload/), and dlopen on the same path while the
#        old handle is alive silently returns the OLD code.
#
# How to reproduce
#   cd <repo root> && bash experiments/plugin-hotreload/run.sh
#   Needs: zig build already possible, DEEPSEEK_API_KEY, network. Takes ~90s.
#   The script restores the source on exit (trap), so the tree stays clean.

set -uo pipefail
cd "$(dirname "$0")/../.."

SRC=src/plugins/tools.zig
BAK=$(mktemp)
cp "$SRC" "$BAK"
restore() { cp "$BAK" "$SRC"; rm -f "$BAK"; }
trap restore EXIT

zig build || { echo "build failed"; exit 1; }

# Edit the marker at t=25s: turn 1 (a real API call) is done by then.
( sleep 25; sed -i 's/\[exit {d}\]/[EXIT {d}]/' "$SRC" ) &

{
  echo "Run the bash tool with: echo first. Answer with the command output only."
  sleep 50
  echo "Run the bash tool with: echo second. Answer with the command output only."
} | timeout 200 ./zig-out/bin/dsh_zig >/dev/null 2>&1

LATEST=$(find "$HOME/.dsh/sessions" -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2)
echo "session log: $LATEST"

python3 - "$LATEST" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
tool_results = [r["content"] for r in rows
                if r.get("type") == "message" and r.get("role") == "tool"]
for i, c in enumerate(tool_results, 1):
    print(f"tool result #{i}: {c!r}")
ok = (len(tool_results) >= 2
      and "[exit 0]" in tool_results[0]
      and "[EXIT 0]" in tool_results[1])
print("PASS: hot reload changed behaviour inside a running process"
      if ok else "FAIL: behaviour did not change")
sys.exit(0 if ok else 1)
PY
