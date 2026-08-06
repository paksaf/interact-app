# Handoff — INTERACT Talk (interact-app): 3 call/update UX defects

**Date:** 2026-08-05 · **Updated:** 2026-08-06 — REVIEWED & RESOLVED
**Branch:** `feat/talk-offline-mesh-camera` (72 untracked + 61 modified files of unrelated in-flight work — scope any commit carefully)
**Reported by operator:** (1) auto-update should be silent, previously "bumping over main screen"; (2) caller cancels but callee keeps ringing; (3) incoming call shows no caller profile picture.

## Outcome: only ONE of the three was a code defect.

| # | Report | Verdict | Action |
|---|---|---|---|
| 3 | No caller avatar | **Data gap** — full chain verified correct end-to-end | None. 24 of 25 users simply haven't set a photo |
| 1 | Auto-update bumps main screen | **Already fixed** in a prior session | None. Verify on device |
| 2 | Callee keeps ringing after cancel | **REAL — fixed 2026-08-06** | Code change in 2 files, needs two-phone test |

---

## 🟢 #3 — No caller profile picture — NOT A CODE BUG

Verified at every hop: DB column `users.avatar_url` → `/talk/calls/incoming` selects and emits `callerAvatar` → `/talk/calls/ring` emits it → `call_signaling.dart:45` parses it → `incoming_call_screen.dart:168-192` renders a `CircleAvatar` with `NetworkImage(call.callerAvatar!.trim())` **and an initials fallback**.

Operator's query settled it: `total 25 | with_avatar 1`.

The upload path also exists and works on **both** surfaces — `profile_setup_screen.dart:51` (onboarding) and `me_tab.dart:193` `_pickAvatar` wired to `onTap` at line 413 (existing users can change it later). So there is no missing feature and nothing to fix.

**If avatars still don't show once users set them,** check that the stored URL is absolute and reachable from the device — `NetworkImage` fails silently and falls back to initials, which looks identical to "no avatar". Separately, `lib/services/callkit_service.dart` (the native OS call screen) takes its own avatar parameter and is an independent path from the Flutter screen — unverified.

---

## 🟢 #1 — Auto-update interrupts the main screen — ALREADY FIXED

`lib/widgets/in_app_update_banner.dart` documents the exact reported symptom in its own header:

> *"do NOT use MaterialBanner here. MaterialBanner pushes the whole Scaffold body down, and AppShell used to clear+re-show it on every download progress tick — on Samsung that 'bumps' the Calls/Chats dashboard repeatedly."*

Current design is already what the operator wants: an inline strip driven by `ListenableBuilder` that updates **in place**, mounted passively on SignIn (`sign_in_screen.dart:221`) and AppShell (`app_shell.dart:170`). Auto-download defaults ON, so the download itself is silent; only a small "NEW / Update / Later" strip appears. `showInAppUpdateBanner()` is retained as a `@Deprecated` no-op shim so old call sites still compile.

**Nothing to change.** Confirm the operator's installed build predates that fix.

---

## 🔴 #2 — Caller cancels, callee keeps ringing — FIXED 2026-08-06

**The screen that matters is `MeetingRoomScreen` (`/room`), not the LiveKit one.** `TalkFlags.callRoomPath()` returns `/call-lk` only when `TALK_LK_CALLS` is set; it defaults to empty, so `CallRoomLiveKitScreen` is dead code in every default build. An earlier draft of this handoff analysed the wrong screen.

Ruled out by inspection:
- **Server is correct.** `/talk/calls/respond` maps `cancel` → status `cancelled` via a race-safe `updateMany` scoped to `{ id, callerId, status: "ringing" }`; `/talk/calls/incoming` only returns `ringing` + unexpired. Once the POST lands, the callee dismisses on its next 3s poll.
- **The `_connecting` guard is correct.** `_connecting` flips false in exactly one place — `onConnectionState == Connected` — which only happens after the callee answers. So while ringing, the cancel is genuinely attempted.

**Two real faults, both in `_teardown()`:**

1. **Fire-and-forget during teardown.** The cancel was `unawaited(...)`, and `respond()` first awaits `_headers()`, which can trigger a token refresh (gotcha #69) — a whole extra round trip *before* the POST starts. A fast hang-up popped the route with the request still queued.
2. **Unguarded `ref.read` on the dispose path.** `dispose()` → `_hangup()` → `_teardown()`, and `_teardown()` called `ref.read(callSignalingProvider)` **without** try/catch — while `dispose()` wraps its *own* `ref.read` calls in try/catch with the comment *"provider may already be disposed."* On back-press/swipe-away that throw discarded the cancel **and** aborted the rest of teardown (WS close, pc close, renderers, wakelock) — a resource leak on top of the ringing bug, since `_torndown` was already set to `true`.

**The fix** (`meeting_room_screen.dart`, mirrored in `call_room_livekit_screen.dart`):
- Capture `CallSignaling` into `_signaling` at `initState` — the dispose path no longer depends on `ref.read`.
- New `_sendCancelIfNeeded()` returns the in-flight future, or null when no cancel is warranted (not host / no invite id / peer already answered). Guarded by `_cancelSent` so it fires at most once.
- Kick it off **first** in `_teardown()` so the POST is on the wire immediately, then **await it last** with a 4s bound — it overlaps the socket/pc/renderer shutdown, so it normally costs no extra time. Never rethrows.

**TEST (two phones, mandatory — cannot be verified by `flutter analyze`):**
1. A calls B → B rings → A cancels **via the red end-call button** → B's ring stops within ~3s.
2. Repeat, but A **back-presses / swipes away** instead of using the button — this is the path that was fully broken.
3. Immediately call B again — it must ring (verifies gotcha #65's `clear()` still holds).
4. Normal answered call → hang up → confirm no spurious "cancelled" and teardown is clean.

Residual: the callee polls every 3s, so up to ~3s of extra ring is expected by design. Not the reported fault.

---

## Working notes

- **Branch hygiene:** stage specific files; do not `git add -A`.
- **Phantom git locks:** `.git/index.lock` / `HEAD.lock` appear with no git process running (cause unidentified — NOT FUSE, disproved by `scripts/diagnose-mount.sh`). A failed commit followed by a "successful" push ships an *older* commit. **Use `scripts/safe-commit.sh`.**
- **`flutter analyze` proves nothing here** — all 17 packages analyzed clean while #2 was live.
- **Phone A** = Samsung SM-A235F, arm64-v8a, USB `R68T304FX1F`. Fat APK only (gotcha #67b).

## ⚠️ Method note

On 2026-08-05 I asserted a defect from a **grep hit without reading the surrounding code** three times, and was wrong each time (rsync "destroyed" voice assets; `install.sh` "needed" `curl -f`; the avatar `CircleAvatar` "unbound"). Reviewing this document on 2026-08-06 caught **three more** errors of the same kind, all in the #2 analysis: I claimed `dispose()` held a belt-and-braces cancel (it does not — it only stops captions), I analysed the flag-gated LiveKit screen as though it were live (it is not), and I never checked the server route or the `_connecting` guard before naming a root cause.

**Read the function, not the line — and confirm the code path is actually reachable before diagnosing it.** In a codebase this mature the default assumption should be that a feature is present and something upstream (data, config, deploy, or a feature flag) is the fault. That was true for two of these three reports.
