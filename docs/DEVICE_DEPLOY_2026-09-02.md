# Device deploy — build 6069

**Version:** `0.5.25+6069`  
**Last verified:** 2026-09-02 — A23 + iPad + iPhone Paksaf all on 6069

Unified deploy entry point for phones, tablet (iPad), and car head unit.

## Lab deploy status (2026-09-02)

| Device | Build | Install |
|--------|-------|---------|
| Samsung A23 (`R68T304FX1F`) | 6069 | ✅ USB arm64 |
| iPad (`00008112-000609C611F9401E`) | 6069 | ✅ `flutter install` |
| iPhone Paksaf (`00008101-001A3CE400E1401E`) | 6069 | ✅ `flutter install` |
| Car HU | — | ☐ Set `CAR_HOST` or use `car-wifi` |

Resume context: `SESSION.md` (repo root) · workspace handoff: `docs/sessions/SESSION_2026-09-02_TALK_6069_DEPLOY.md`

## Quick commands

```bash
cd ~/dev/INTERACT/apps/interact-app
cp .device-env.example .device-env   # once — set CAR_HOST when known

bash deploy-devices.sh ipad          # iPad USB
bash deploy-devices.sh a23           # Samsung USB
bash deploy-devices.sh car           # Car HU WiFi adb (v7a)
bash deploy-devices.sh car-wifi      # Car HU browser sideload :8766
bash deploy-devices.sh iphone        # iPhone USB
bash deploy-devices.sh mobile        # A23 + iPad
```

Each target runs `flutter pub get`, `flutter analyze`, build, then install/serve.

## What's in 6069

| Feature | Status |
|---------|--------|
| Friends & Family panel (`6068`) | ✅ |
| Find friends hub | ✅ |
| Location trace links | ✅ |
| iPad / car deploy scripts | ✅ **this build** |
| Signal E2E encrypt | 🚧 Phase 1.5 started — libsignal dep + identity store (not live yet) |

## E2E honesty

6069 does **not** turn on chat encryption for users. `shouldEncryptOutbound` stays `false` until pre-key API + field proof. See `docs/E2E_PHASE1_5_2026-09-02.md`.
