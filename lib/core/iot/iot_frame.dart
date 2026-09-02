// SPDX-License-Identifier: AGPL-3.0
//
// Universal IoT frame — one envelope for LoRa ESP32, 433/868 RF→HTTP bridges,
// Meshtastic (UTF-8 line until protobuf TX), BLE mesh relay, AutoSense gateway.
//
// Wire format: single-line JSON, ≤200 bytes on LoRa paths (short keys).
// Legacy plain UTF-8 is wrapped on ingest as kind=telemetry, bearer=plain.

import 'dart:convert';
import 'dart:math';

/// Transport that carried this frame (short wire codes in JSON key `b`).
enum IotBearer {
  plain('pl'),
  loraBle('lb'),
  rfHttp('rh'),
  meshtastic('ms'),
  bleMesh('bm'),
  autosense('as');

  const IotBearer(this.wire);
  final String wire;

  static IotBearer? parse(String? wire) {
    if (wire == null) return null;
    for (final b in IotBearer.values) {
      if (b.wire == wire) return b;
    }
    return null;
  }

  String get label => switch (this) {
        IotBearer.plain => 'Plain text',
        IotBearer.loraBle => 'LoRa (BLE bridge)',
        IotBearer.rfHttp => '433/868 RF → HTTP',
        IotBearer.meshtastic => 'Meshtastic',
        IotBearer.bleMesh => 'BLE mesh',
        IotBearer.autosense => 'AutoSense car',
      };
}

enum IotFrameKind {
  telemetry('t'),
  command('c'),
  ack('a'),
  ping('p'),
  alert('l');

  const IotFrameKind(this.wire);
  final String wire;

  static IotFrameKind? parse(String? wire) {
    if (wire == null) return null;
    for (final k in IotFrameKind.values) {
      if (k.wire == wire) return k;
    }
    return null;
  }

  String get label => switch (this) {
        IotFrameKind.telemetry => 'Telemetry',
        IotFrameKind.command => 'Command',
        IotFrameKind.ack => 'ACK',
        IotFrameKind.ping => 'Ping',
        IotFrameKind.alert => 'Alert',
      };
}

/// Inbound or outbound IoT message with optional ACK correlation.
class IotFrame {
  const IotFrame({
    this.v = 1,
    required this.id,
    required this.kind,
    required this.bearer,
    required this.body,
    this.ackFor,
    this.meta = const {},
    this.at,
    this.isMine = false,
  });

  final int v;
  final String id;
  final IotFrameKind kind;
  final IotBearer bearer;
  final String body;
  final String? ackFor;
  final Map<String, dynamic> meta;
  final DateTime? at;
  final bool isMine;

  static String newId() {
    final r = Random();
    return List.generate(8, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  IotFrame copyWith({
    int? v,
    String? id,
    IotFrameKind? kind,
    IotBearer? bearer,
    String? body,
    String? ackFor,
    Map<String, dynamic>? meta,
    DateTime? at,
    bool? isMine,
  }) {
    return IotFrame(
      v: v ?? this.v,
      id: id ?? this.id,
      kind: kind ?? this.kind,
      bearer: bearer ?? this.bearer,
      body: body ?? this.body,
      ackFor: ackFor ?? this.ackFor,
      meta: meta ?? this.meta,
      at: at ?? this.at,
      isMine: isMine ?? this.isMine,
    );
  }

  Map<String, dynamic> toJson() => {
        'v': v,
        'id': id,
        'k': kind.wire,
        'b': bearer.wire,
        'body': body,
        if (ackFor != null && ackFor!.isNotEmpty) 'af': ackFor,
        if (meta.isNotEmpty) 'm': meta,
      };

  String encodeLine() {
    final line = jsonEncode(toJson());
    if (line.length > 200) {
      throw ArgumentError('IoT frame exceeds 200 bytes (${line.length}) for LoRa');
    }
    return line;
  }

  /// Parse envelope JSON or wrap legacy plain text.
  static IotFrame? decode(String raw, {IotBearer defaultBearer = IotBearer.plain}) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    if (trimmed.startsWith('{')) {
      try {
        final m = jsonDecode(trimmed) as Map<String, dynamic>;
        final kind = IotFrameKind.parse(m['k'] as String?) ??
            IotFrameKind.telemetry;
        final bearer =
            IotBearer.parse(m['b'] as String?) ?? defaultBearer;
        final id = (m['id'] as String?)?.trim();
        if (id == null || id.isEmpty) return null;
        final body = (m['body'] as String?) ?? '';
        return IotFrame(
          v: (m['v'] as num?)?.toInt() ?? 1,
          id: id,
          kind: kind,
          bearer: bearer,
          body: body,
          ackFor: m['af'] as String?,
          meta: (m['m'] is Map)
              ? Map<String, dynamic>.from(m['m'] as Map)
              : const {},
          at: DateTime.now(),
        );
      } catch (_) {
        return null;
      }
    }

    // Legacy: plain UTF-8 from DIY LoRa firmware or Meshtastic text.
    return IotFrame(
      id: newId(),
      kind: _guessKind(trimmed),
      bearer: defaultBearer,
      body: trimmed,
      at: DateTime.now(),
    );
  }

  static IotFrameKind _guessKind(String body) {
    final lower = body.toLowerCase();
    if (lower.startsWith('ping') || lower.contains('ping')) {
      return IotFrameKind.ping;
    }
    if (lower.startsWith('ack') || lower == 'ok' || lower == 'nack') {
      return IotFrameKind.ack;
    }
    if (lower.contains('alert') ||
        lower.contains('alarm') ||
        lower.contains('gate_open')) {
      return IotFrameKind.alert;
    }
    return IotFrameKind.telemetry;
  }

  /// Build an ACK frame replying to [inbound].
  factory IotFrame.ack({
    required IotFrame inbound,
    required String code,
    required IotBearer bearer,
  }) {
    return IotFrame(
      id: newId(),
      kind: IotFrameKind.ack,
      bearer: bearer,
      body: code,
      ackFor: inbound.id,
      meta: ifMeta(inbound),
      at: DateTime.now(),
      isMine: true,
    );
  }

  static Map<String, dynamic> ifMeta(IotFrame inbound) {
    final src = inbound.meta['src'];
    if (src == null) return const {};
    return {'src': src};
  }
}
