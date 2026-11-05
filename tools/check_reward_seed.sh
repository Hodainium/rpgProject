#!/usr/bin/env bash
# Lists every Enemy.Boss in client-godot/content/ that has no entry in infra/economy/reward_rules.json
# (spec economy-rewards 8.1). A report for the designer, NOT a test: adding a boss can never fail the suite.
#   tools/check_reward_seed.sh [seed file]
root=$(cd "$(dirname "$0")/.." && pwd)
seed=${1:-$root/infra/economy/reward_rules.json}
missing=0
while IFS= read -r file; do
  id=$(grep -m1 -E '^id = ' "$file" | sed -E 's/^id = &?"([^"]+)".*/\1/' | tr -d '\r')
  [ -z "$id" ] && continue
  if ! grep -qF "\"sourceId\": \"$id\"" "$seed"; then
    echo "no reward rule: $id  ($file)"
    missing=$((missing + 1))
  fi
done < <(grep -rl --include=*.tres '"Enemy.Boss"' "$root/client-godot/content")
echo "$missing boss(es) without a seed rule"
exit 0
