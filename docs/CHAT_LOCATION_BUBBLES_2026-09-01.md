# Chat location bubbles

**Build:** `0.5.16+6058`

Shared GPS pins in chat now render as a **map preview bubble** with tap-to-navigate instead of raw text.

---

## Send (unchanged)

Chat attach → **Share location** → `_shareLocationPin()` sends:

```
📍 Shared location
31.520400, 74.358700
interactmaps://route?lat=…&lng=…
https://talk.interactpak.com/j/LOC?lat=…&lng=…
```

---

## Receive (new)

| Component | Path |
|-----------|------|
| Parser | `lib/utils/shared_location_pin.dart` |
| Maps launcher | `lib/utils/shared_location_launcher.dart` |
| Bubble UI | `lib/widgets/chat/location_pin_bubble.dart` |
| Thread integration | `lib/screens/chat/chat_thread_screen.dart` |

Open order: `interactmaps://` → Google Maps web → talk `/j/LOC` link.

---

## Deep link

`https://talk.interactpak.com/j/LOC?lat=&lng=` → in-app `_LocationPinDeepLinkScreen` (`main.dart`).

---

## Donors

| Repo | Reused |
|------|--------|
| interact-app `_shareLocationPin` | Wire format |
| sahulat-app | `flutter_map` pattern (static OSM tile used here — no new dep) |
| `_AttachmentView._open` | `url_launcher` external open |

---

## Tests

`flutter test test/shared_location_pin_test.dart`

**Field test:** `RF-LOC-BUBBLE-1` — send pin A→B, B sees map bubble, tap opens Maps.
