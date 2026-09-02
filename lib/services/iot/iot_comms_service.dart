// SPDX-License-Identifier: AGPL-3.0
//
// Unified IoT comms — one phone, any gateway (LoRa BLE, RF→HTTP, future Meshtastic TX).

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/iot/iot_ack_presets.dart';
import '../../core/iot/iot_frame.dart';
import '../../utils/shared_location_pin.dart';
import '../lora_bridge_service.dart';

enum IotTransportKind { none, loraBle, rfHttp }

/// Active gateway + inbox for IoT frames (ACK, telemetry, commands).
class IotCommsService {
  IotCommsService._();
  static final IotCommsService instance = IotCommsService._();

  static const _prefRfPoll = 'iot.rf_http.poll_url';
  static const _prefRfAck = 'iot.rf_http.ack_url';

  final _inboxCtrl = StreamController<IotFrame>.broadcast();
  final List<IotFrame> _history = [];

  StreamSubscription<LoraBridgeMessage>? _loraSub;
  Timer? _rfPollTimer;
  int? _lastRfPayloadHash;

  IotTransportKind _transport = IotTransportKind.none;
  String? _rfPollUrl;
  String? _rfAckUrl;
  bool _connected = false;
  String? _status;

  Stream<IotFrame> get inbox => _inboxCtrl.stream;
  List<IotFrame> get history => List.unmodifiable(_history);
  IotTransportKind get transport => _transport;
  bool get isConnected => _connected;
  String? get status => _status;
  String? get rfPollUrl => _rfPollUrl;
  String? get rfAckUrl => _rfAckUrl;

  Future<void> loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    _rfPollUrl = prefs.getString(_prefRfPoll);
    _rfAckUrl = prefs.getString(_prefRfAck);
  }

  /// App-launch resume: if an RF-HTTP poll URL was saved, restart the 5s poll
  /// so GPS/IoT trackers appear on the map with zero taps. LoRa-over-BLE is NOT
  /// auto-resumed (the bridge may be out of range) — that stays a manual tap.
  Future<void> autoReconnectFromPrefs() async {
    if (_connected) return;
    await loadPrefs();
    final url = _rfPollUrl?.trim();
    if (url == null || url.isEmpty) return;
    try {
      await connectRfHttp(url, ackUrl: _rfAckUrl);
    } catch (e) {
      debugPrint('[iot] RF-HTTP auto-reconnect failed: $e');
    }
  }

  Future<void> saveRfHttpUrls(String pollUrl, {String? ackUrl}) async {
    _rfPollUrl = pollUrl.trim();
    _rfAckUrl = ackUrl?.trim().isEmpty == true ? null : ackUrl?.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefRfPoll, _rfPollUrl!);
    if (_rfAckUrl != null) {
      await prefs.setString(_prefRfAck, _rfAckUrl!);
    } else {
      await prefs.remove(_prefRfAck);
    }
  }

  // ── LoRa BLE (InteractLoRaBridge) ───────────────────────────────────

  Future<void> connectLoRa(LoraBridgeCandidate candidate) async {
    await disconnect();
    final lora = LoraBridgeService.instance;
    await lora.connect(candidate);
    _loraSub = lora.messages.listen((m) {
      if (m.isMine) return;
      final frame = IotFrame.decode(m.body, defaultBearer: IotBearer.loraBle);
      if (frame == null) return;
      _push(frame.copyWith(at: m.at));
    });
    _transport = IotTransportKind.loraBle;
    _connected = true;
    _status = 'LoRa bridge: ${candidate.name}';
  }

  // ── RF → HTTP (433 MHz rtl_433 / Pi gateway / AutoSense edge) ───────

  Future<void> connectRfHttp(String pollUrl, {String? ackUrl}) async {
    await disconnect();
    final poll = pollUrl.trim();
    if (poll.isEmpty) throw ArgumentError('Poll URL required');
    await saveRfHttpUrls(poll, ackUrl: ackUrl);
    _rfAckUrl = ackUrl ?? _deriveAckUrl(poll);
    _transport = IotTransportKind.rfHttp;
    _connected = true;
    _status = 'RF HTTP poll: $poll';
    await _pollRfOnce();
    _rfPollTimer?.cancel();
    _rfPollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_pollRfOnce());
    });
  }

  String? _deriveAckUrl(String pollUrl) {
    final uri = Uri.tryParse(pollUrl);
    if (uri == null) return null;
    if (uri.path.endsWith('/tpms')) {
      return uri.replace(path: uri.path.replaceAll('/tpms', '/ack')).toString();
    }
    if (uri.path == '/' || uri.path.isEmpty) {
      return uri.replace(path: '/ack').toString();
    }
    return uri.replace(path: '${uri.path}/ack').toString();
  }

  Future<void> _pollRfOnce() async {
    final url = _rfPollUrl;
    if (url == null) return;
    try {
      final resp = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 4));
      if (resp.statusCode >= 400) {
        _status = 'RF poll HTTP ${resp.statusCode}';
        return;
      }
      final hash = resp.body.hashCode;
      if (hash == _lastRfPayloadHash) return;
      _lastRfPayloadHash = hash;
      final frames = _framesFromRfJson(resp.body);
      for (final f in frames) {
        _push(f);
      }
      _status = 'RF HTTP · ${frames.length} signal(s)';
    } catch (e) {
      _status = 'RF poll failed: $e';
      debugPrint('[iot-comms] rf poll: $e');
    }
  }

  List<IotFrame> _framesFromRfJson(String body) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return [
        IotFrame(
          id: IotFrame.newId(),
          kind: IotFrameKind.telemetry,
          bearer: IotBearer.rfHttp,
          body: body.trim(),
          at: DateTime.now(),
          meta: const {'raw': true},
        ),
      ];
    }

    if (decoded is Map) {
      final map = Map<String, dynamic>.from(decoded);
      final gps = parseIotGpsMeta(map);
      if (gps != null) {
        final id = (map['id'] as String?) ??
            (map['device'] as String?) ??
            IotFrame.newId();
        return [
          IotFrame(
            id: id.toString(),
            kind: IotFrameKind.telemetry,
            bearer: IotBearer.rfHttp,
            body: (map['body'] as String?) ?? 'gps',
            at: DateTime.now(),
            meta: map,
          ),
        ];
      }
      final id = (decoded['id'] as String?) ??
          (decoded['device'] as String?) ??
          IotFrame.newId();
      // Full envelope passthrough
      if (decoded.containsKey('k') && decoded.containsKey('body')) {
        final f = IotFrame.decode(jsonEncode(decoded),
            defaultBearer: IotBearer.rfHttp);
        if (f != null) return [f];
      }
      final alert = decoded['alert'] ?? decoded['event'] ?? decoded['signal'];
      if (alert != null) {
        return [
          IotFrame(
            id: id.toString(),
            kind: IotFrameKind.alert,
            bearer: IotBearer.rfHttp,
            body: alert.toString(),
            at: DateTime.now(),
            meta: Map<String, dynamic>.from(decoded),
          ),
        ];
      }
      return [
        IotFrame(
          id: id.toString(),
          kind: IotFrameKind.telemetry,
          bearer: IotBearer.rfHttp,
          body: jsonEncode(decoded),
          at: DateTime.now(),
          meta: Map<String, dynamic>.from(decoded),
        ),
      ];
    }
    return [
      IotFrame(
        id: IotFrame.newId(),
        kind: IotFrameKind.telemetry,
        bearer: IotBearer.rfHttp,
        body: decoded.toString(),
        at: DateTime.now(),
      ),
    ];
  }

  // ── Send / ACK ─────────────────────────────────────────────────────

  Future<IotFrame> sendAck({
    required IotFrame inbound,
    required IotAckPreset preset,
  }) {
    final frame = IotFrame.ack(
      inbound: inbound,
      code: preset.code,
      bearer: _bearerForTransport(),
    );
    return sendFrame(frame);
  }

  Future<IotFrame> sendText(String text) {
    final frame = IotFrame(
      id: IotFrame.newId(),
      kind: IotFrameKind.command,
      bearer: _bearerForTransport(),
      body: text.trim(),
      at: DateTime.now(),
      isMine: true,
    );
    return sendFrame(frame);
  }

  Future<IotFrame> sendFrame(IotFrame frame) async {
    switch (_transport) {
      case IotTransportKind.loraBle:
        try {
          await LoraBridgeService.instance.sendText(frame.encodeLine());
        } catch (_) {
          // DIY firmware accepts plain UTF-8 — degrade for long payloads.
          await LoraBridgeService.instance.sendText(frame.body);
        }
        break;
      case IotTransportKind.rfHttp:
        await _postRfAck(frame);
        break;
      case IotTransportKind.none:
        throw StateError('Connect LoRa bridge or RF HTTP gateway first.');
    }
    _push(frame);
    return frame;
  }

  Future<void> _postRfAck(IotFrame frame) async {
    final ackUrl = _rfAckUrl ?? _rfPollUrl;
    if (ackUrl == null) throw StateError('RF ack URL not configured');
    final uri = Uri.parse(ackUrl);
    final resp = await http
        .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: frame.encodeLine(),
        )
        .timeout(const Duration(seconds: 4));
    if (resp.statusCode >= 400) {
      // Fallback: some bridges only accept GET with query
      final q = uri.replace(
        queryParameters: {
          'ack': frame.body,
          if (frame.ackFor != null) 'af': frame.ackFor!,
          'id': frame.id,
        },
      );
      final getResp = await http.get(q).timeout(const Duration(seconds: 4));
      if (getResp.statusCode >= 400) {
        throw StateError('RF ack failed HTTP ${resp.statusCode}');
      }
    }
  }

  IotBearer _bearerForTransport() => switch (_transport) {
        IotTransportKind.loraBle => IotBearer.loraBle,
        IotTransportKind.rfHttp => IotBearer.rfHttp,
        IotTransportKind.none => IotBearer.plain,
      };

  void _push(IotFrame frame) {
    _history.add(frame);
    if (_history.length > 200) {
      _history.removeRange(0, _history.length - 200);
    }
    if (!_inboxCtrl.isClosed) _inboxCtrl.add(frame);
  }

  Future<void> disconnect() async {
    await _loraSub?.cancel();
    _loraSub = null;
    _rfPollTimer?.cancel();
    _rfPollTimer = null;
    _lastRfPayloadHash = null;
    if (_transport == IotTransportKind.loraBle) {
      await LoraBridgeService.instance.disconnect();
    }
    _transport = IotTransportKind.none;
    _connected = false;
    _status = null;
  }

  Future<void> dispose() async {
    await disconnect();
    await _inboxCtrl.close();
  }
}
