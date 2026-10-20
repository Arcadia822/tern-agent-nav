#!/bin/bash
# verify-tern-agent-nav helper drives. Whole world command passed as ONE ctl argument
# (multi-argv silently no-ops for plugin commands — see SKILL.md Drive section).
set -u
export TERN_DAEMON_SOCKET="${TERN_DAEMON_SOCKET:-/tmp/tern-sandbox/daemon.sock}"
export TERN_CONFIG_DIR="${TERN_CONFIG_DIR:-/tmp/tern-sandbox/config}"
W="${W:-tern ctl --control /tmp/nav-verify.sock}"
KV="/tmp/tern-sandbox/config/plugin-data/agent-nav/kv.json"

case "${1:-}" in
  doctor)
    tern plugin list
    tern ls --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print("sessions:", ", ".join(f"{s["name"]}({len(s["tabs"])})" for s in d["sessions"]))'
    tern capture "Agent Navigations" --surfaces | head -1
    $W state | python3 -c 'import json,sys; d=json.load(sys.stdin); print("window ok:", d.get("ok"), "theme:", d.get("theme"), d.get("theme_light"), d.get("theme_dark"))'
    ;;
  rows)
    tern capture "Agent Navigations" --surfaces
    ;;
  toggle)
    nav() { tern ls --json | python3 -c '
import json,sys
d=json.load(sys.stdin)
for s in d["sessions"]:
  for t in s["tabs"]:
    for b in t["blocks"]:
      if b["title"]=="Agent Navigations":
        sp=t["splits"].get("Split")
        left=(sp or {}).get("a")=={"Leaf":b["id"]}
        share=(sp or {}).get("ratio") if left else (1-(sp or {}).get("ratio",0))
        print(f"{s["name"]}/tab{t["number"]} cols={b["cols"]} railshare={share:.3f} left={left}")
'; }
    echo "before: $(nav)"; echo "kv: $(cat "$KV" | tr -d '\n ')"
    $W 'palette "Agent Nav"'; sleep 2; $W key enter; sleep 3
    echo "after 1: $(nav)"; echo "kv: $(cat "$KV" | tr -d '\n ')"
    $W 'palette "Agent Nav"'; sleep 2; $W key enter; sleep 4
    echo "after 2: $(nav)"; echo "kv: $(cat "$KV" | tr -d '\n ')"
    ;;
  shot)
    name="${2:?usage: verify.sh shot NAME}"
    (cd /tmp && $W "shot $name") || (cd ~ && $W "shot $name")
    find /tmp ~ -maxdepth 5 -path "*target/shots/tern/live/$name.png" -mmin -2 2>/dev/null | head -1
    ;;
  *)
    echo "usage: verify.sh {doctor|rows|toggle|shot NAME}" >&2; exit 2;;
esac
