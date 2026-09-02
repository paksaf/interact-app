// SPDX-License-Identifier: AGPL-3.0
//
// Sahulat pre-key API client — Phase 1.5 (fail-soft until backend ships).

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../api_base.dart';
import '../auth_service.dart';

final e2ePreKeyApiProvider = Provider<E2ePreKeyApi>((ref) {
  return E2ePreKeyApi(ref.read(authServiceProvider));
});

/// Bundle JSON shape matches libsignal PreKeyBundle serialization on server.
class E2ePreKeyApi {
  E2ePreKeyApi(this._auth);
  final AuthService _auth;

  String get _base => ApiBase.current;

  Future<Map<String, String>> _headers() async {
    final token = await _auth.token();
    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  /// Upload identity + one-time pre-keys + signed pre-key after local install.
  Future<bool> uploadBundle(Map<String, dynamic> bundle) async {
    try {
      final res = await http.post(
        Uri.parse('$_base/api/v1/talk/e2e/prekeys'),
        headers: await _headers(),
        body: jsonEncode(bundle),
      );
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  /// Fetch a peer's pre-key bundle by Talk user id.
  Future<Map<String, dynamic>?> fetchPeerBundle(String peerUserId) async {
    try {
      final res = await http.get(
        Uri.parse('$_base/api/v1/talk/e2e/prekeys/$peerUserId'),
        headers: await _headers(),
      );
      if (res.statusCode == 404) return null;
      if (res.statusCode >= 400) return null;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final data = body['data'];
      if (data is Map<String, dynamic>) return data;
      if (data is Map) return data.cast<String, dynamic>();
      return body;
    } catch (_) {
      return null;
    }
  }
}
