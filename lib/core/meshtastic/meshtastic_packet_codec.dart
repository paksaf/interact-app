// SPDX-License-Identifier: AGPL-3.0
//
// Minimal Meshtastic ToRadio → MeshPacket → Data protobuf encoder for
// TEXT_MESSAGE_APP (portnum 1). Enough for BLE ToRadio writes without
// pulling meshtastic_flutter / flutter_blue_plus.

import 'dart:convert';
import 'dart:typed_data';

/// Broadcast destination on the mesh.
const kMeshtasticBroadcast = 0xFFFFFFFF;

class MeshtasticPacketCodec {
  /// Encode UTF-8 text as a ToRadio MeshPacket (decoded, not encrypted).
  static Uint8List encodeTextToRadio(
    String text, {
    int to = kMeshtasticBroadcast,
    int channel = 0,
  }) {
    final payload = utf8.encode(text);
    if (payload.isEmpty) {
      throw ArgumentError('empty text');
    }
    if (payload.length > 200) {
      throw ArgumentError('Meshtastic text max ~200 bytes, got ${payload.length}');
    }
    final data = _encodeData(portnum: 1, payload: Uint8List.fromList(payload));
    final mesh = _encodeMeshPacket(to: to, channel: channel, decoded: data);
    return _encodeToRadio(mesh);
  }

  static Uint8List _encodeToRadio(Uint8List meshPacket) {
    final out = BytesBuilder();
    _writeTag(out, 1, 2); // packet — length-delimited
    _writeVarint(out, meshPacket.length);
    out.add(meshPacket);
    return out.toBytes();
  }

  static Uint8List _encodeMeshPacket({
    required int to,
    required int channel,
    required Uint8List decoded,
  }) {
    final out = BytesBuilder();
    _writeTag(out, 2, 0); // to — varint
    _writeVarint(out, to);
    if (channel != 0) {
      _writeTag(out, 3, 0); // channel
      _writeVarint(out, channel);
    }
    _writeTag(out, 5, 2); // decoded — length-delimited
    _writeVarint(out, decoded.length);
    out.add(decoded);
    return out.toBytes();
  }

  static Uint8List _encodeData({
    required int portnum,
    required Uint8List payload,
  }) {
    final out = BytesBuilder();
    _writeTag(out, 1, 0); // portnum
    _writeVarint(out, portnum);
    _writeTag(out, 2, 2); // payload
    _writeVarint(out, payload.length);
    out.add(payload);
    return out.toBytes();
  }

  static void _writeTag(BytesBuilder out, int fieldNumber, int wireType) {
    _writeVarint(out, (fieldNumber << 3) | wireType);
  }

  static void _writeVarint(BytesBuilder out, int value) {
    var v = value;
    while (v > 0x7F) {
      out.addByte((v & 0x7F) | 0x80);
      v >>= 7;
    }
    out.addByte(v & 0x7F);
  }
}
