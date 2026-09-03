import 'package:flutter_test/flutter_test.dart';
import 'package:interact/models/guest_join.dart';

void main() {
  group('GuestAdmissionPolicy.fromWire', () {
    test('maps known policies', () {
      expect(
        GuestAdmissionPolicy.fromWire('passcode'),
        GuestAdmissionPolicy.passcode,
      );
      expect(
        GuestAdmissionPolicy.fromWire('admit'),
        GuestAdmissionPolicy.admit,
      );
      expect(GuestAdmissionPolicy.fromWire('off'), GuestAdmissionPolicy.off);
    });

    test('unknown defaults to off', () {
      expect(GuestAdmissionPolicy.fromWire(null), GuestAdmissionPolicy.off);
      expect(GuestAdmissionPolicy.fromWire('bogus'), GuestAdmissionPolicy.off);
    });
  });

  group('GuestPolicyState.fromData', () {
    test('parses GET/PUT response shape', () {
      final state = GuestPolicyState.fromData({
        'policy': 'admit',
        'guestRole': 'listener',
        'hasPasscode': false,
        'guestUrl': 'https://talk.interactpak.com/join/ABC123',
      });
      expect(state.policy, GuestAdmissionPolicy.admit);
      expect(state.guestRole, GuestJoinRole.listener);
      expect(state.hasPasscode, isFalse);
      expect(state.guestUrl, 'https://talk.interactpak.com/join/ABC123');
      expect(state.guestsEnabled, isTrue);
    });

    test('off policy is not guestsEnabled', () {
      final state = GuestPolicyState.fromData({'policy': 'off'});
      expect(state.guestsEnabled, isFalse);
      expect(state.guestRole, GuestJoinRole.speaker);
    });
  });

  group('GuestJoinRequest.fromJson', () {
    test('parses waiting queue item', () {
      final r = GuestJoinRequest.fromJson({
        'id': 'req-1',
        'displayName': 'Ali',
        'createdAt': '2026-09-03T10:00:00.000Z',
      });
      expect(r.id, 'req-1');
      expect(r.displayName, 'Ali');
      expect(r.createdAt, isNotNull);
    });

    test('drops empty id via caller filter pattern', () {
      final r = GuestJoinRequest.fromJson({'displayName': 'No id'});
      expect(r.id, isEmpty);
    });
  });
}
