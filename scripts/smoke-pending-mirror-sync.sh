#!/usr/bin/env bash
# Manual smoke: pending IL + theme PUT retry on app open/resume.
#
# Prerequisites: signed-in Talk app on device; optional TALK_TOKEN for curl checks.
#
# IL reminder retry:
#   1. Enable airplane mode
#   2. Welcome → Reminder → save ("Retry test IL …")
#   3. Confirm local chip shows due reminder; no IL task yet
#   4. Disable airplane mode, force-quit app, reopen
#   5. Expect log: [WelcomeMemory] IL flush synced 1 reminder(s)
#      or [IlScheduleSync] POST 201
#
# Theme PUT retry:
#   1. Airplane mode ON
#   2. Me → Theme → pick Forest (local applies instantly)
#   3. Force-quit, airplane OFF, reopen
#   4. Expect log: [ThemeController] theme PUT ok
#
# Resume retry (without force-quit):
#   1. Airplane ON → set theme or reminder
#   2. Send app to background, airplane OFF, return to app
#   3. Within ~15s of last flush, resume may throttle; wait 15s or cold-start
#
# Optional API probe (server-side theme):
#   TALK_TOKEN='eyJ…' bash scripts/smoke-pending-mirror-sync.sh

set -euo pipefail
BASE="${TALK_API_BASE:-https://qurbanisahulat.com}"
TOKEN="${TALK_TOKEN:-}"

if [[ -z "$TOKEN" ]]; then
  echo "Set TALK_TOKEN to probe GET/PUT /api/v1/talk/profile/theme (optional)."
  exit 0
fi

auth=(-H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -H "Accept: application/json")

echo "==> GET /api/v1/talk/profile/theme"
curl -sS "${auth[@]}" "$BASE/api/v1/talk/profile/theme" | python3 -m json.tool

echo ""
echo "==> PUT sample theme (forest seed)"
curl -sS -w "\nHTTP %{http_code}\n" -X PUT "${auth[@]}" "$BASE/api/v1/talk/profile/theme" \
  -d '{"mode":"system","seed":2139610442,"accent":4287049793}'

echo ""
echo "==> POST IL schedule task (welcome reminder shape)"
IL_BASE="${IL_API_BASE:-https://lifestyle.interactpak.com/api}"
curl -sS -w "\nHTTP %{http_code}\n" -X POST "${auth[@]}" "$IL_BASE/schedule/tasks" \
  -d "$(python3 -c "import json,datetime; print(json.dumps({'title':'Smoke retry test','dueAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'source':'talk-welcome'}))")"
