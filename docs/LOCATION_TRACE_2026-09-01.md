# Location trace — build 6066

Share GPS and trace people/devices across phone, chat, and IoT bearers.

## Entry points

| Path | How |
|------|-----|
| **Me → Offline hub → Location trace** | `/location-trace` |
| **Chat attach → Share location** | One-shot pin (OfflineRouter) |
| **Chat attach → Share live location** | 15 min / 1 hr / until stop |
| **IoT gateway** | RF poll JSON with `lat`/`lng` |

## Phone GPS (app)

- **Static pin** — `formatLocationPinBody()` → `MessageRepository.sendText()` → cloud → LAN → BLE → queue.
- **Live share** — `LocationShareService` sends a pin every 60s until duration ends; shows on **Location trace** with Live chip.
- **Compact BLE** — `loc:31.52040,74.35870` inside talk envelope (≤180 B).

## IoT / small devices

Poll JSON examples:

```json
{"device":"tracker-001","lat":30.15,"lng":71.52,"acc":12,"body":"gps"}
```

```json
{"v":1,"id":"gps1","k":"t","b":"rh","body":"gps","m":{"lat":30.15,"lng":71.52,"device":"car-pi"}}
```

Fixes appear in **Location trace** and **IoT alerts** chat as map bubbles.

## Trace registry

`LocationTraceService` stores the latest fix per entity (user id or device id) in SharedPreferences. Sources: `phone`, `iot`, `ble`, `lan`.

## Files

| File | Role |
|------|------|
| `lib/models/location_fix.dart` | Fix model + source enum |
| `lib/services/location_trace_service.dart` | Registry + ingest hooks |
| `lib/services/location_share_service.dart` | Live share timer |
| `lib/screens/location/location_trace_screen.dart` | Trace UI |
| `lib/utils/shared_location_pin.dart` | Pin format + compact `loc:` |
| `test/location_trace_test.dart` | Unit tests |

Field test: **RF-LOC-TRACE-1** — A shares live in 1:1 chat; B sees updates on trace + thread bubble.

---

**Build:** `0.5.22+6066`
