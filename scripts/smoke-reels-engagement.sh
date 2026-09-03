#!/usr/bin/env bash
# Reel engagement + deep-link smoke tests (API + device checklist).
# Usage:
#   bash scripts/smoke-reels-engagement.sh
#   TALK_TOKEN='eyJ…' REEL_ID='uuid' bash scripts/smoke-reels-engagement.sh
set -euo pipefail

BASE="${TALK_API_BASE:-https://qurbanisahulat.com}"
FAKE_UUID="00000000-0000-0000-0000-000000000001"

pass=0
fail=0

check() {
  local name="$1"
  local expect_code="$2"
  local body="$3"
  local code="$4"
  if [[ "$code" == "$expect_code ]]; then
    echo "✅ $name (HTTP $code)"
    pass=$((pass + 1))
  else
    echo "❌ $name — expected HTTP $expect_code, got $code"
    echo "   body: $body"
    fail=$((fail + 1))
  fi
}

echo "==> Talk API base: $BASE"
echo ""

# Anonymous view on missing reel — route alive, honest 404
resp=$(curl -sS -w "\n%{http_code}" -X POST \
  "$BASE/api/v1/me/reels/$FAKE_UUID/view" \
  -H "Content-Type: application/json" -d '{}')
body=$(echo "$resp" | sed '$d')
code=$(echo "$resp" | tail -1)
check "POST view (missing reel → 404)" "404" "$body" "$code"

# Public GET by id — missing reel
resp=$(curl -sS -w "\n%{http_code}" \
  "$BASE/api/v1/reels/$FAKE_UUID" \
  -H "Accept: application/json")
body=$(echo "$resp" | sed '$d')
code=$(echo "$resp" | tail -1)
check "GET /api/v1/reels/{id} (missing → 404)" "404" "$body" "$code"

# Authenticated flows (optional — set TALK_TOKEN + REEL_ID from device)
if [[ -n "${TALK_TOKEN:-}" ]]; then
  auth=(-H "Authorization: Bearer $TALK_TOKEN" -H "Accept: application/json")

  resp=$(curl -sS -w "\n%{http_code}" "${auth[@]}" "$BASE/api/v1/me/reels")
  body=$(echo "$resp" | sed '$d')
  code=$(echo "$resp" | tail -1)
  check "GET /api/v1/me/reels (auth)" "200" "$body" "$code"

  if [[ -z "${REEL_ID:-}" ]]; then
    REEL_ID=$(echo "$body" | python3 -c "
import json,sys
d=json.load(sys.stdin)
reels=(d.get('data') or {}).get('reels') or []
print(reels[0]['id'] if reels else '')
" 2>/dev/null || true)
  fi

  if [[ -n "$REEL_ID" ]]; then
    echo ""
    echo "==> Using REEL_ID=$REEL_ID"

    resp=$(curl -sS -w "\n%{http_code}" "${auth[@]}" "$BASE/api/v1/reels/$REEL_ID")
    body=$(echo "$resp" | sed '$d')
    code=$(echo "$resp" | tail -1)
    check "GET /api/v1/reels/{id} (exists)" "200" "$body" "$code"

    resp=$(curl -sS -w "\n%{http_code}" -X POST \
      "$BASE/api/v1/me/reels/$REEL_ID/view" \
      -H "Authorization: Bearer $TALK_TOKEN" \
      -H "Content-Type: application/json" -d '{}')
    body=$(echo "$resp" | sed '$d')
    code=$(echo "$resp" | tail -1)
    check "POST view (real reel)" "200" "$body" "$code"

    resp=$(curl -sS -w "\n%{http_code}" -X POST \
      "$BASE/api/v1/me/reels/$REEL_ID/like" \
      -H "Authorization: Bearer $TALK_TOKEN")
    body=$(echo "$resp" | sed '$d')
    code=$(echo "$resp" | tail -1)
    check "POST like (toggle)" "200" "$body" "$code"

    resp=$(curl -sS -w "\n%{http_code}" -X POST \
      "$BASE/api/v1/me/reels/$REEL_ID/comments" \
      -H "Authorization: Bearer $TALK_TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"body":"smoke test comment"}')
    body=$(echo "$resp" | sed '$d')
    code=$(echo "$resp" | tail -1)
    check "POST comment" "200" "$body" "$code"

    resp=$(curl -sS -w "\n%{http_code}" -X POST \
      "$BASE/api/v1/me/reels/$REEL_ID/share" \
      -H "Authorization: Bearer $TALK_TOKEN")
    body=$(echo "$resp" | sed '$d')
    code=$(echo "$resp" | tail -1)
    check "POST share" "200" "$body" "$code"
  else
    echo "ℹ️  No reels on account — skip engagement on real id (add one via app first)."
  fi
else
  echo ""
  echo "ℹ️  Set TALK_TOKEN (JWT from signed-in app) to run authenticated engagement tests."
fi

echo ""
echo "==> API summary: $pass passed, $fail failed"
echo ""
cat <<'DEVICE'

── Device smoke checklist (0.5.26+6071 or newer) ──

1. Sign in → Friends & Family → Add reel (+)
2. Paste YouTube URL → reel opens → engagement rail visible (❤️ 💬 ↗️ 👁)
3. Like → count bumps; close & reopen → persists
4. Comment → post → appears in sheet
5. Share → OS sheet → URL is https://talk.interactpak.com/reel/{uuid}
6. Upload photo/video → local reel → rail works
7. Deep link (after rebuild with /reel route):
     adb shell am start -a android.intent.action.VIEW \
       -d "https://talk.interactpak.com/reel/REEL_UUID"
   → app opens viewer directly

DEVICE

if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
