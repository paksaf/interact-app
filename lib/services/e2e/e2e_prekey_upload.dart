// SPDX-License-Identifier: AGPL-3.0
//
// Upload local public pre-keys after identity install (fail-soft).

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'e2e_bundle_builder.dart';
import 'e2e_identity_manager.dart';
import 'e2e_prekey_api.dart';
import 'e2e_prekey_store.dart';

final e2ePreKeyUploadProvider = Provider<E2ePreKeyUpload>((ref) {
  return E2ePreKeyUpload(ref.read(e2ePreKeyApiProvider));
});

class E2ePreKeyUpload {
  E2ePreKeyUpload(this._api);
  final E2ePreKeyApi _api;

  /// Push public bundle to Sahulat if local pre-keys exist. Never throws.
  Future<bool> syncIfNeeded() async {
    try {
      final record = await E2eIdentityManager.instance.loadRecord();
      if (record == null) return false;
      if (!await E2ePreKeyStore.instance.hasStoredPreKeys) return false;

      final preKeys = await E2ePreKeyStore.instance.loadPreKeys();
      final signed = await E2ePreKeyStore.instance.loadSignedPreKey();
      if (preKeys.isEmpty || signed == null) return false;

      final bundle = buildE2eUploadBundle(
        identity: record,
        preKeys: preKeys,
        signedPreKey: signed,
      );
      return _api.uploadBundle(bundle);
    } catch (_) {
      return false;
    }
  }
}
