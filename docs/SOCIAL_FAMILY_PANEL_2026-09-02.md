# Friends & Family social panel — build 6068

**Version:** `0.5.24+6068`

Local-first social surface for family updates, curated circles, find-friends hub, and location trace shortcuts.

## Entry points

| Path | How |
|------|-----|
| **Me → Friends & Family → Family & Friends panel** | `/social-panel` |
| **Me → Find friends** | `/find-friends` |
| **Contacts app bar** (feed icon) | `/social-panel` |
| **Me → Location trace** | `/location-trace` |

## Tabs (social panel)

1. **Feed** — your status/photo posts + recent channel announcements; audience filter (Family / Friends / Everyone)
2. **Circles** — add contacts to Family, Close friends, or Friends (local SharedPreferences)
3. **Track** — shortcuts to location trace, live share in chat, family announcement channels

## Find friends hub

- @username lookup → open chat or invite
- Phone / email → direct thread
- Device contacts picker
- Invite link / SMS (existing `/invite`)

## What is NOT shipped in 6068

| Feature | Status |
|---------|--------|
| **Signal E2E (libsignal)** | Phase 1.5 stub — HTTPS transit today |
| **Server-backed social feed** | Local posts only; cloud sync when Sahulat `/api/v1/talk/social/*` lands |
| **Always-on background family map** | Use chat live share + `/location-trace` |

## Field cases

- **SOCIAL-FEED-1** — Post family update → appears in Feed tab
- **SOCIAL-CIRCLE-1** — Add contact to Family circle → stories row shows name
- **FIND-FRIENDS-1** — @username lookup opens thread
- **RF-LOC-TRACE-1** — Location trace from Track tab (existing)

## Files

```
lib/models/social_post.dart
lib/models/family_circle.dart
lib/services/family_circle_store.dart
lib/services/social_feed_service.dart
lib/screens/social/social_panel_screen.dart
lib/screens/social/find_friends_screen.dart
test/family_circle_test.dart
test/social_post_test.dart
```
