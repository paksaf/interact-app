# Townhall audience analytics

**Build:** `0.5.16+6058` · **Client:** `LiveRoomScreen` · **Backend:** qurbanisahulat `/api/v1/talk/live/*`

Hosts and moderators see live **viewer count**, **focused vs unfocused** split, and **peak concurrent** while a townhall is running.

---

## Architecture

```
Viewer device (LiveRoomScreen)
       │ every 30s + on app resume/background
       ▼
POST /api/v1/talk/live/presence/beat  { roomCode, role, focus, area }
       │
       ▼
talk_live_room_beats (Postgres, TTL ~90s on lastBeatAt)
       │
       ▼
GET /api/v1/talk/live/analytics?code=TOWN42  (host|moderator only)
       │
       ▼
Host top bar: "N watching" · "X focused" · "Y unfocused"
Roster panel: Audience summary + per-participant focus from LiveKit metadata
```

Parallel path: each client also publishes `focus` in **LiveKit participant metadata** so the SFU roster shows focused/unfocused even before the backend is deployed.

---

## Client files

| File | Role |
|------|------|
| `lib/services/live_room_presence_service.dart` | 30s beats, lifecycle focus, host poll |
| `lib/services/live_api.dart` | `livePresenceBeat`, `livePresenceLeave`, `liveAnalytics` |
| `lib/services/livekit_service.dart` | `publishAppFocus()`, `LiveTile.focus` |
| `lib/screens/meeting/live_room_screen.dart` | `WidgetsBindingObserver`, host chips |

---

## Backend

| Route | Auth |
|-------|------|
| `POST .../presence/beat` | Session JWT |
| `POST .../presence/leave` | Session JWT |
| `GET .../analytics?code=` | Session + host/moderator beat in room |

**Migration:** `prisma/migrations/20260901_talk_live_room_analytics/migration.sql`

Run on qurbanisahulat deploy:

```bash
cd apps/qurbanisahulat
npx prisma migrate deploy   # or apply SQL manually
npx prisma generate
```

---

## Acceptance (manual)

1. Host starts townhall on phone A; 2+ listeners join on B/C.
2. Host top bar shows **watching ≥ 2** within ~30s (after backend migrate).
3. Listener backgrounds app → host sees **unfocused** count rise.
4. Listener returns → **focused** count rises.
5. Roster subtitle shows `focused` / `unfocused` per tile when metadata updates.

**Field test id (add to Field validation):** `RF-TOWNHALL-AUDIT-1`

---

## Donor patterns reused

| Donor | Pattern |
|-------|---------|
| `presence_service.dart` | 45s app-wide heartbeat |
| `talk/presence/beat/route.ts` | Session upsert + fire-and-forget client |
| `livekit_service.dart` `_publishSelfInfo` | Participant metadata for host roster |
| IoT doc sequence diagrams | ASCII flow in this doc |

---

## Not in v1

- Passive viewers (not in LiveKit room)
- AI engagement scoring from captions
- Geo-IP host dashboard (only device-reported coarse `area`)
- LiveKit webhook as source of truth (phase 2)
