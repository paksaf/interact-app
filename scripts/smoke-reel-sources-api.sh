#!/usr/bin/env bash
# Create one reel per source via Talk API (device A prep helper).
# Usage: TALK_TOKEN='eyJ…' bash scripts/smoke-reel-sources-api.sh
set -euo pipefail

BASE="${TALK_API_BASE:-https://qurbanisahulat.com}"
TOKEN="${TALK_TOKEN:?Set TALK_TOKEN (JWT from signed-in Talk app)}"

auth=(-H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -H "Accept: application/json")

post_url() {
  local label="$1" url="$2"
  echo ""
  echo "==> POST reel ($label)"
  resp=$(curl -sS -w "\n%{http_code}" -X POST "$BASE/api/v1/me/reels" \
    "${auth[@]}" -d "$(python3 -c "import json; print(json.dumps({'url': '$url'}))")")
  body=$(echo "$resp" | sed '$d')
  code=$(echo "$resp" | tail -1)
  echo "HTTP $code"
  echo "$body" | python3 -m json.tool 2>/dev/null || echo "$body"
  if [[ "$code" != "200" && "$code" != "201" ]]; then
    return 1
  fi
  echo "$body" | python3 -c "
import json,sys
d=json.load(sys.stdin)
r=(d.get('data') or {}).get('reel') or {}
print('reelId:', r.get('id',''))
print('platform:', r.get('platform',''))
print('embedHtml:', 'yes' if r.get('embedHtml') else 'no')
print('thumbnailUrl:', 'yes' if r.get('thumbnailUrl') else 'no')
"
}

post_url youtube "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
post_url tiktok "https://www.tiktok.com/@scout2015/video/6718339390846452485"
post_url twitter "https://twitter.com/Twitter/status/1447922823037270021"

echo ""
echo "==> POST caption assist (local upload helper — empty title)"
resp=$(curl -sS -w "\n%{http_code}" -X POST "$BASE/api/v1/me/reels/caption" \
  "${auth[@]}" -d '{"transcript":"Family gathering at the farm, Eid celebrations."}')
body=$(echo "$resp" | sed '$d')
code=$(echo "$resp" | tail -1)
echo "HTTP $code (200=caption, 503=no AI key — both OK)"
echo "$body" | python3 -m json.tool 2>/dev/null || echo "$body"

echo ""
echo "Local photo/video: use Add reel → upload on device (multipart /api/v1/media/upload then POST /me/reels/local)."
