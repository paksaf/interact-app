# Friends & Family social panel — build 6069

**Version:** `0.5.25+6069`

Local-first social surface for family updates, curated circles, find-friends hub, and location trace shortcuts. **6069 adds WhatsApp-style status row + reels viewer for photo/video posts.**

## Entry points

| Path | How |
|------|-----|
| **Me → Friends & Family → Family & Friends panel** | `/social-panel` |
| **Me → Find friends** | `/find-friends` |
| **Contacts app bar** (feed icon) | `/social-panel` |
| **Me → Location trace** | `/location-trace` |

## Tabs (social panel)

1. **Feed** — status row (24h media), media-forward cards, text/photo/video posts + channel announcements; audience filter (Family / Friends / Everyone)
2. **Circles** — add contacts to Family, Close friends, or Friends (local SharedPreferences)
3. **Track** — shortcuts to location trace, live share in chat, family announcement channels

## Share / media (6069)

- **Share FAB** — text update, gallery photo/video, camera photo/record (60s cap)
- **Status row** — gradient rings for authors with media in the last 24h; tap opens full-screen reels viewer
- **Feed cards** — 4:5 photos, 9:16 video preview; tap → progress bars, tap left/right to skip, hold to pause
- Media copied to `Documents/social_media/` on post

## Find friends hub

- @username lookup → open chat or invite
- Phone / email → direct thread
- Device contacts picker
- Invite link / SMS (existing `/invite`)

## What is NOT shipped in 6069

| Feature | Status |
|---------|--------|
| **Signal E2E (libsignal)** | Phase 1.5 stub — HTTPS transit today |
| **Server-backed social feed** | Local posts only; cloud sync when Sahulat `/api/v1/talk/social/*` lands |
| **Always-on background family map** | Use chat live share + `/location-trace` |

## Field cases

- **SOCIAL-FEED-1** — Post family update → appears in Feed tab
- **SOCIAL-MEDIA-1** — Post photo/video → status ring + reels viewer
- **SOCIAL-CIRCLE-1** — Add contact to Family circle
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
lib/widgets/social/social_stories_row.dart
lib/widgets/social/social_reels_viewer.dart
lib/widgets/social/social_feed_card.dart
test/family_circle_test.dart
test/social_post_test.dart
```
