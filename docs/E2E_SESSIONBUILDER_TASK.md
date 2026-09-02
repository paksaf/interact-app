> STATUS 2026-09-02: IMPLEMENTED by Claude (Cowork) — do NOT rebuild.
> Files: `e2e_signal_store.dart` (persistent store), `e2e_session_service.dart`
> (SessionBuilder+SessionCipher), rewired `e2e_crypto_service.dart`, and inbound
> decrypt wired in `message_repository.dart`. Envelope payload is `<type>:<base64>`
> inside `e2e:v1:`. Flag stays OFF. REMAINING: `flutter analyze` pass + the
> two-device E2E-1 test below. This doc is kept as the spec/acceptance record.

# E2E Phase 1.5 — SessionBuilder + SessionCipher (Cursor task)

Goal: turn the existing pre-key scaffolding into working 1:1 Signal
encryption. Keep it **gated off** (`INTERACT_E2E` stays `false`) until the
two-device test passes. Do NOT flip the flag in this task.

## What already exists (do not rebuild)
- `E2eIdentityManager` (`lib/services/e2e/e2e_identity_manager.dart`) —
  generates/persists `IdentityKeyPair` + `registrationId` + pre-keys on
  `install()`. Exposes `loadIdentityKeyPair()`, `loadRecord()`, `isInstalled`.
- `E2ePreKeyStore` (`e2e_prekey_store.dart`) — persists `PreKeyRecord`s +
  `SignedPreKeyRecord` in secure storage (`loadPreKeys`, `loadSignedPreKey`,
  `save`). NOTE: this is storage only — it is NOT a libsignal
  `SignalProtocolStore`.
- `E2ePreKeyApi` (`e2e_prekey_api.dart`) — `uploadBundle(...)` and
  `fetchPeerBundle(peerUserId)` → `Map<String,dynamic>` (server consumes one
  OTPK per fetch). Backend routes live + deployed-local:
  `POST /api/v1/talk/e2e/prekeys`, `GET /api/v1/talk/e2e/prekeys/[userId]`.
- `E2eCryptoService` (`e2e_crypto_service.dart`) — orchestrator.
  `bootstrap()` installs identity + uploads pre-keys. `encryptOutbound()`
  currently THROWS (fail-closed), `decryptInbound()` returns a placeholder.
  Gated by `_kE2eEnabled` (`INTERACT_E2E`, default false) + `status==active`.
- `e2e_envelope.dart` — wire format `e2e:v1:<base64>`; `wrap/unwrap`,
  `isE2eEnvelope`.
- Outbound hook is ALREADY wired: `message_repository.dart:118` calls
  `E2eCryptoService.instance.encryptOutbound(...)` when `shouldEncryptOutbound`.

## What to build

### 1. Persistent `SignalProtocolStore`  (the core piece)
Create `lib/services/e2e/e2e_signal_store.dart` implementing libsignal's
four stores (`SessionStore`, `PreKeyStore`, `SignedPreKeyStore`,
`IdentityKeyStore`) — or the combined `SignalProtocolStore` — backed by
persistent storage (Hive box or flutter_secure_storage), NOT in-memory.
Sessions MUST persist across app restarts or the double-ratchet state is lost
and messages become undecryptable. Seed it from `E2eIdentityManager`
(identity keypair + registrationId) and `E2ePreKeyStore` (pre-keys + signed
pre-key). Use `InMemorySignalProtocolStore` only as an API reference for the
method set to implement.

### 2. SessionBuilder — establish a session from a peer bundle
Add `Future<bool> ensureSession(String peerUserId)` to a new
`E2eSessionService` (or into `E2eCryptoService`):
- `final data = await E2ePreKeyApi(...).fetchPeerBundle(peerUserId);`
  null → status `pendingPeer`, return false.
- Reconstruct a `PreKeyBundle(registrationId, deviceId=1, preKeyId,
  preKeyPublic, signedPreKeyId, signedPreKeyPublic, signedPreKeySignature,
  identityKey)` from the JSON (confirm field names against the backend
  `talk-e2e-prekeys.ts` serialization).
- `await SessionBuilder(store..., SignalProtocolAddress(peerUserId, 1))
     .processPreKeyBundle(bundle);`
- On success mark that peer session active.

### 3. Encrypt — implement `encryptOutbound`
Replace the `throw` with:
- `final cipher = SessionCipher(store..., SignalProtocolAddress(peerUserId,1));`
- `final ct = await cipher.encrypt(utf8.encode(plaintext) as Uint8List);`
- Encode BOTH the ciphertext type and bytes so decrypt can pick the right
  parser. Extend the envelope to `e2e:v1:<type>:<base64>` where `<type>` is
  `ct.getType()` (prekey vs whisper). Update `e2e_envelope.dart` accordingly.

### 4. Decrypt — implement `decryptInbound` AND wire it into the inbound path
- Parse envelope → `type` + base64 bytes.
- type == prekey → `cipher.decrypt(PreKeySignalMessage.fromSerialized(bytes))`
  else → `cipher.decryptFromSignal(SignalMessage.fromSerialized(bytes))`.
- Return `utf8.decode(plaintext)`. On failure keep a safe placeholder (never
  show raw ciphertext).
- IMPORTANT: inbound decrypt is currently NOT called anywhere. Wire
  `decryptInbound` into the inbound message path (in `message_repository`
  where inbound bodies are ingested, and/or `inbound_funnel.dart`) so a
  received `e2e:v1:` body is decrypted before storage/display.

### 5. Status
Make `status` reflect real per-peer session state; keep the global
`E2eStatus.active` meaning "at least one usable session" or refactor to
per-thread. `pendingPeer` when `fetchPeerBundle` returns null.

## Guardrails (must hold)
- `INTERACT_E2E` stays `false` in this task. All new code runs only when the
  flag is on; the default (cloud) path must be byte-for-byte unchanged.
- Keep `encryptOutbound` fail-closed: if a session can't be built, throw
  rather than send plaintext under an encrypted flag.
- `flutter analyze` clean; verify every libsignal signature against the
  installed `libsignal_protocol_dart 0.8.2` (e.g. `SignedPreKeyRecord` uses
  `fromSerialized`, not `fromBuffer` — a known 0.8.2 gotcha).

## Acceptance — E2E-1 two-device test
Build two devices with `--dart-define=INTERACT_E2E=true`. Device A messages
device B in a 1:1 thread:
1. B decrypts and displays the plaintext.
2. The stored/DB body and any server log show only `e2e:v1:...` ciphertext —
   never the plaintext.
3. Kill and relaunch B, send again — still decrypts (proves persistent store).
Only after this passes do we consider enabling the flag for a build.
