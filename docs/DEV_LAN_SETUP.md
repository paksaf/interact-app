# Dev LAN device registry — INTERACT Talk lab

**Build:** `0.5.25+6069` · Copy `.device-env.example` → `.device-env` for local overrides.

| Device | Transport | Target command | APK / bundle |
|--------|-----------|----------------|--------------|
| **Samsung A23** | USB | `bash deploy-devices.sh a23` | arm64-v8a |
| **iPad** | USB cable | `bash deploy-devices.sh ipad` | iOS Runner.app |
| **iPhone (Paksaf)** | USB cable | `bash deploy-devices.sh iphone` | iOS Runner.app |
| **Car head unit (CMWFYX)** | WiFi adb | `bash deploy-devices.sh car` | armeabi-v7a |
| **Car head unit (browser)** | WiFi HTTP | `bash deploy-devices.sh car-wifi` | v7a-only on `:8766` |
| **Phone sideload** | WiFi HTTP | `bash deploy-devices.sh phone-wifi` | fat universal `:8765` |
| **Bravia TV** | WiFi adb | `bash deploy-devices.sh tv` | armeabi-v7a |

## Default IDs (`.device-env.example`)

```
A23_SERIAL=R68T304FX1F
IPAD_UDID=00008112-000609C611F9401E
IPHONE_UDID=00008101-001A3CE400E1401E
TV_HOST=192.168.100.4:5555
CAR_HOST=192.168.100.50:5555   ← set after wireless debugging on dash
```

## Car head unit (first time)

1. Settings → About → tap Build number 7× → Developer options  
2. Enable USB debugging + **Wireless debugging**  
3. Pair from Mac: `adb connect <HU_IP>:5555`  
4. Verify ABI: `adb shell getprop ro.product.cpu.abi` → expect `armeabi-v7a`  
5. Set `CAR_HOST` in `.device-env` → `bash deploy-devices.sh car`  

If adb is awkward on dash: `bash deploy-devices.sh car-wifi` and open the URL on the HU browser.

## iPad (USB)

1. Trust Mac, enable Developer Mode on iPad  
2. `bash deploy-devices.sh ipad`  
3. Or Xcode → Runner.xcworkspace → select iPad → Run  

## One-shot mobile lab

```bash
bash deploy-devices.sh mobile    # A23 + iPad
bash deploy-devices.sh all-lab   # A23 + iPad + car-wifi server
```

See also: `docs/DEVICE_DEPLOY_2026-09-02.md`, `docs/hardware/car-headunit-install/`
