#!/bin/bash
set -uo pipefail
export HOME=/root
WEBHOOK="${HA_WEBHOOK_URL:?HA_WEBHOOK_URL not set, see /etc/ansible-update.env}"
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

cd /root/ansible-prometheus
if git pull --ff-only >"$LOG" 2>&1 && ansible-playbook -i inventory/hosts.yml update.yml >>"$LOG" 2>&1; then
  STATUS=ok
else
  STATUS=failed
fi

SUMMARY=$( {
  grep -E '"msg": "(Reboot required|Manual update)' "$LOG" | sed 's/.*"msg": "//; s/"$//'
  sed -n '/PLAY RECAP/,$p' "$LOG" | grep -E 'failed=[1-9]|unreachable=[1-9]' | awk '{print $1 " fehlgeschlagen"}'
} | sort -u )

python3 - "$STATUS" "$SUMMARY" "$WEBHOOK" <<'PY'
import json, sys, urllib.request
status, summary, url = sys.argv[1:4]
req = urllib.request.Request(url, data=json.dumps({"status": status, "summary": summary}).encode(), headers={"Content-Type": "application/json"})
urllib.request.urlopen(req, timeout=10)
PY

cat "$LOG"
[ "$STATUS" = ok ]
