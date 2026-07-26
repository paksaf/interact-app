# interact-app — closing the two gaps (2026-07-24)

The feature board's two "honest gaps" are **background call ring (push)** and **live in-call captions**. Good news from a full trace: the Talk backend already does most of the work.

---
## GAP 1 — Background call ring (Android) — ~1 client file + 1 operator env

### What already exists (no work)
- `qurbanisahulat.com/api/v1/talk/calls/ring` already calls `sendPushToUser()` for the killed-app ring.
- `src/lib/push/{fcmV1,send,config}.ts` — full FCM HTTP v1 sender, reads the `device_tokens` table, gated on `SAHULAT_FCM_SERVICE_ACCOUNT_PATH` (unset ⇒ "stub"/dark = the board's "Creds-gated").
- Token register endpoint exists: `POST /api/v1/me/push-tokens {platform, token, appId}` (Bearer auth, idempotent upsert).

### What's missing = 2 things
**(A) Operator — point the backend at the FCM creds we already have (interact-lifestyle project).**
```bash
ssh interact
# place the interact-lifestyle admin-SDK JSON (same one il-api/FleetOps use) somewhere readable by the qurbanisahulat service, e.g.:
#   /etc/sahulat/fcm-interact-lifestyle.json
nano /srv/qurbanisahulat/.env         # or wherever PM2 loads env
#   SAHULAT_FCM_SERVICE_ACCOUNT_PATH=/etc/sahulat/fcm-interact-lifestyle.json
#   (optional) SAHULAT_FCM_PROJECT_ID=interact-lifestyle
pm2 restart qurbanisahulat --update-env
# verify: pushConfigSummary() mode should now be "fcm" not "stub".
```
Also add interact-app's Android package to the **interact-lifestyle** Firebase project (console → Add app → Android, package = `com.interactpak.interact_talk`) → download `google-services.json` → `android/app/google-services.json`. (Same project the fleet already uses.)

**Payload contract (fixed 2026-07-25):** ring route sends `type: "call_ring"` + `callId` (= threadId). Client accepts `call_ring` and legacy `talk_call`.

**(B) Client — interact-app must obtain + register an FCM token and ring on the background data-message.** Apply ALL of the following together (adding firebase imports without the deps breaks `flutter analyze`).

#### pubspec.yaml (add)
```yaml
  firebase_core: ^3.6.0
  firebase_messaging: ^15.1.3
```

#### android/build.gradle (project) — plugins/classpath
```gradle
plugins { id 'com.google.gms.google-services' version '4.4.2' apply false }
```
#### android/app/build.gradle (app)
```gradle
plugins { id 'com.google.gms.google-services' }
```
#### android/app/src/main/AndroidManifest.xml (inside <manifest> / <application>)
```xml
<uses-permission android:name="android.permission.USE_FULL_SCREEN_INTENT"/>
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
<meta-data android:name="com.google.firebase.messaging.default_notification_channel_id"
           android:value="interact_calls"/>
```

#### lib/services/push_service.dart (NEW)
```dart
// FCM push: registers the device token with the Talk backend and rings on a
// background/killed-app call data-message. Reuses the interact-lifestyle
// Firebase project (server sends via SAHULAT_FCM_SERVICE_ACCOUNT_PATH).
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'auth_service.dart';
import 'notification_service.dart';

const _kBase = 'https://qurbanisahulat.com';

// Top-level: runs in a separate isolate when the app is backgrounded/killed.
@pragma('vm:entry-point')
Future<void> firebaseBgHandler(RemoteMessage m) async {
  await Firebase.initializeApp();
  if (m.data['type'] == 'call_ring') {
    await NotificationService.instance.init();
    await NotificationService.instance.showIncomingCall(
      callId: m.data['callId'] ?? '',
      callerName: m.data['callerName'] ?? 'INTERACT caller',
      mode: m.data['mode'] ?? 'video',
    );
  }
}

class PushService {
  PushService._();
  static final PushService instance = PushService._();

  Future<void> init(AuthService auth) async {
    await FirebaseMessaging.instance.requestPermission();
    FirebaseMessaging.onBackgroundMessage(firebaseBgHandler);
    final token = await FirebaseMessaging.instance.getToken();
    if (token != null) await _register(token, auth);
    FirebaseMessaging.instance.onTokenRefresh.listen((t) => _register(t, auth));
    // Foreground: ring immediately.
    FirebaseMessaging.onMessage.listen((m) {
      if (m.data['type'] == 'call_ring') {
        NotificationService.instance.showIncomingCall(
          callId: m.data['callId'] ?? '',
          callerName: m.data['callerName'] ?? 'INTERACT caller',
          mode: m.data['mode'] ?? 'video',
        );
      }
    });
  }

  Future<void> _register(String token, AuthService auth) async {
    final jwt = await auth.token();
    if (jwt == null) return;
    try {
      await http.post(
        Uri.parse('$_kBase/api/v1/me/push-tokens'),
        headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $jwt'},
        body: jsonEncode({'platform': 'android', 'token': token, 'appId': 'com.interactpak.interact_app'}),
      );
    } catch (_) {/* retry next boot */}
  }
}
```

#### lib/services/notification_service.dart (ADD this method to the class)
```dart
  /// Full-screen incoming-call notification (rings even when the app is killed).
  Future<void> showIncomingCall({
    required String callId,
    required String callerName,
    required String mode,
  }) async {
    await init();
    await _plugin.show(
      callId.hashCode & 0x7fffffff,
      'Incoming ${mode == 'voice' ? 'voice' : 'video'} call',
      callerName,
      NotificationDetails(
        android: AndroidNotificationDetails(
          'interact_calls',
          'Calls',
          channelDescription: 'Incoming voice/video calls',
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.call,
          fullScreenIntent: true,      // launches the full-screen ring UI
          ongoing: true,
          playSound: true,
          audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
        ),
      ),
      payload: 'call:$callId:$mode',
    );
  }
```

#### lib/main.dart (make main async + init Firebase before runApp)
```dart
import 'package:firebase_core/firebase_core.dart';
import 'services/push_service.dart';
...
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const ProviderScope(child: InteractApp()));
}
```
Then in `_GateState.initState` (after `signedIn` is true) call `PushService.instance.init(auth)` — that's where a valid token exists.

### Server: make `ring` include the call payload (verify)
`ring/route.ts` already calls `sendPushToUser`. Confirm the payload it sends carries `data: {type:'call_ring', callId, callerName, mode}` (data-message, NOT notification-only) so the background handler fires. If it currently sends a `notification` block, add the `data` fields.

### iOS = still Planned (genuinely blocked)
iOS background ring needs **APNs key + CallKit/VoIP push (PushKit)** — a separate Apple credential + native work. Keep iOS "Planned" until the Apple Developer APNs key is provisioned.

---
## GAP 2 — Live in-call captions

**Status 2026-07-25:** caption-agent deployed on Hetzner as PM2 `interact-caption-agent`
(`:8097`, health reports `configured:true`). Talk API env has `CAPTION_AGENT_URL` +
`CAPTION_AGENT_TOKEN`. Redeploy: `bash interact-realtime/caption-agent/deploy-hetzner.sh`.
Client toggle lives on LiveKit rooms only (`LiveRoomScreen` → Captions).

### Design — backend caption agent

Group calls already run through **LiveKit SFU** (`wss://livekit.interactpak.com`), which is the key enabler: LiveKit lets a server-side participant subscribe to audio tracks. So live captions = a small **caption-agent worker**:
1. Node worker using `livekit-server-sdk` joins the room as a hidden participant, subscribes to each audio track.
2. Streams PCM to **Deepgram streaming STT** (key already in the vault: `fc6fc25caeb4fb8101f4892117f9093054c10597`) — Arabic/Urdu/English models.
3. Publishes interim + final captions back on a LiveKit **data channel** (`topic: captions`, `{participant, text, final}`).
4. Flutter renders them as an overlay in `MeetingRoomScreen`/`LiveRoomScreen`.

Notes: only for LiveKit (group/townhall) calls; 1:1 flutter_webrtc P2P has no media server to tap, so caption-needing 1:1 calls should route via LiveKit too. The existing **meeting-summary/transcript** path (`/api/v1/talk/meetings/summary`) already covers *post-call* text — live is the incremental delta. Effort: M (one worker + a data-channel renderer). Deploy as a systemd/PM2 worker beside the signaling stack.

---
## Verify (after operator + client build)
```bash
# backend live:
ssh interact 'curl -s localhost:PORT/api/v1/... ' # or check pushConfigSummary in logs → mode:"fcm"
# device: log in on 2 phones, kill the callee app, place a call from caller → callee phone rings full-screen.
```
