# interact-app — VPS in-app update + Android build runbook (2026-07-31)

## How updates work

- `lib/services/update_service.dart` — checks `downloads.interactpak.com/interact/latest.json`, compares `version_code` to the installed build, **downloads the ABI-matched APK in-app** (Dio → app support dir), then opens the system installer via `open_filex`.
- **Auto-update default ON** (`SharedPreferences` key `update_auto_download`). Me → App → Auto-update switch to opt out.
- Banner shows `NEW vX.Y.Z · Mon D` from `released_at`, progress while downloading, then **Install now**.
- Publish: `bash scripts/publish-ota.sh` (fat dual-ABI + splits + `released_at` in `latest.json`). Guard: `scripts/verify-apk-abis.sh --require-fat`.

## Manifest fields

```json
{
  "version_name": "0.5.1",
  "version_code": 6037,
  "apk_url": "https://downloads.interactpak.com/interact/interact-0.5.1-6037.apk",
  "apk_url_armeabi_v7a": "…",
  "apk_url_arm64_v8a": "…",
  "released_at": "2026-07-31T06:00:00Z",
  "changelog": "…",
  "force_update": false
}
```

## Build + publish

```bash
cd interact-app
# bump version: in pubspec.yaml  version: 0.5.1+NNNN
bash scripts/publish-ota.sh
```

Phone B (32-bit): fat `apk_url` or `apk_url_armeabi_v7a`. Never ship arm64-only as `apk_url` (Gotcha #67).
