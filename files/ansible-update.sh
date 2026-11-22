#!/usr/bin/env bash
# Managed by Ansible (controller.yml)
# Weekly update run: pull the repo, run update.yml, report the result to Home Assistant.
# Started by ansible-update.service, HA_WEBHOOK_URL comes from /etc/ansible-update.env.
set -uo pipefail

REPO=/root/ansible-prometheus
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

notify() {
  jq -n --arg status "$1" --arg summary "$2" '{status: $status, summary: $summary}' \
    | curl -fsS -m 30 -H 'Content-Type: application/json' -d @- "$HA_WEBHOOK_URL" > /dev/null
}

cd "$REPO" || { notify failed "Repo $REPO not found"; exit 1; }

if ! git pull --ff-only --quiet; then
  notify failed "git pull failed"
  exit 1
fi

ansible-playbook update.yml 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}

# Lines printed by the debug tasks in update.yml
notes=$(grep -oP '"msg": "\K(Reboot required on|Manual update:) [^"]*' "$LOG" | sort -u)

# Hosts with failed or unreachable tasks, from the PLAY RECAP
failed=$(awk '/^PLAY RECAP/ {recap = 1; next}
  recap && /unreachable=|failed=/ {
    if (match($0, /unreachable=[1-9]/) || match($0, /failed=[1-9]/)) print $1
  }' "$LOG" | paste -sd ' ' -)

summary=$notes
if [ -n "$failed" ]; then
  summary=$(printf 'Failed: %s\n%s' "$failed" "$notes")
fi

if [ "$rc" -eq 0 ]; then
  notify ok "$summary"
else
  notify failed "$summary"
fi
exit "$rc"
