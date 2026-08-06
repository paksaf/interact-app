// SPDX-License-Identifier: AGPL-3.0
//
// TalkFlags — compile-time feature flags for INTERACT Talk.
//
// Kept deliberately tiny (a single config getter) so a flag can gate risky
// new paths without threading state through the app. Values are read from
// `--dart-define` at build time, so an unflagged (default) build behaves
// exactly as before.
class TalkFlags {
  const TalkFlags._();

  // Raw dart-define string; empty when unset. We accept `1`/`true`/`yes`/`on`
  // (case-insensitive) so `--dart-define=TALK_LK_CALLS=1` (as documented) and
  // `--dart-define=TALK_LK_CALLS=true` both work — bool.fromEnvironment only
  // parses the literal `true`/`false`, which would silently ignore `=1`.
  static const String _rawLkCalls =
      String.fromEnvironment('TALK_LK_CALLS', defaultValue: '');

  /// Phase 2c Option A — route 1:1 calls through a 2-person LiveKit room
  /// (instead of the peer-to-peer `/room` mesh), which unlocks Townhall-grade
  /// live captions on a call.
  ///
  /// DEFAULT: **false** — when off, 1:1 calls use the existing, untouched P2P
  /// path exactly as today. Enable at build time with:
  ///   flutter build apk --dart-define=TALK_LK_CALLS=1
  static bool get liveKitCalls {
    final v = _rawLkCalls.toLowerCase();
    return v == '1' || v == 'true' || v == 'yes' || v == 'on';
  }

  /// Router path a 1:1 call should push to, honoring [liveKitCalls]. When the
  /// flag is OFF this is always `/room` (the P2P screen) — every call-start
  /// site can call this and stays byte-for-byte identical to today's behaviour
  /// in a default build.
  static String callRoomPath() => liveKitCalls ? '/call-lk' : '/room';
}
