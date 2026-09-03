import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interact/core/chat/message_markup.dart';
import 'package:interact/services/analytics_service.dart';

void main() {
  group('stripMessageMarkup', () {
    test('removes tags keeping inner text', () {
      expect(
        stripMessageMarkup('Hello {b}world{/b}!'),
        'Hello world!',
      );
    });

    test('handles color tags', () {
      expect(
        stripMessageMarkup('{c:BE9A5F}gold{/c}'),
        'gold',
      );
    });
  });

  group('hasMessageMarkup', () {
    test('detects markup', () {
      expect(hasMessageMarkup('plain'), isFalse);
      expect(hasMessageMarkup('{i}x{/i}'), isTrue);
    });
  });

  group('parseMessageMarkupSpans', () {
    test('bold span', () {
      final spans = parseMessageMarkupSpans(
        '{b}hi{/b}',
        baseStyle: const TextStyle(fontSize: 14),
      );
      expect(spans, hasLength(1));
      final span = spans.single as TextSpan;
      expect(span.text, 'hi');
      expect(span.style?.fontWeight, FontWeight.w700);
    });
  });

  group('AnalyticsService.trimQueueForTest', () {
    test('drops stale events', () {
      final now = DateTime.utc(2026, 9, 3).millisecondsSinceEpoch;
      final old = DateTime.utc(2026, 8, 1).toUtc().toIso8601String();
      final trimmed = AnalyticsService.trimQueueForTest([
        {
          'name': 'screen_view',
          'props': {'screen': '/chats'},
          'ts': old,
        },
        {
          'name': 'screen_view',
          'props': {'screen': '/calls'},
          'ts': DateTime.utc(2026, 9, 3).toIso8601String(),
        },
      ], nowMs: now);
      expect(trimmed, hasLength(1));
      expect(
        (trimmed.single['props'] as Map)['screen'],
        '/calls',
      );
    });
  });

  group('AnalyticsService.buildPostBody', () {
    test('top-level anonId and wire event shape', () {
      const anonId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
      const ts = '2026-09-03T10:00:00.000Z';
      final body = AnalyticsService.buildPostBody(
        anonId: anonId,
        queued: [
          {
            'name': 'screen_view',
            'props': {'screen': '/chats'},
            'ts': ts,
          },
          {
            'name': 'feature_use',
            'props': {'feature': 'chat_send'},
            'ts': ts,
          },
          {
            'name': 'session_end',
            'props': {'durationSec': 120},
            'ts': ts,
          },
        ],
      );

      expect(body['anonId'], anonId);
      expect(body.containsKey('events'), isTrue);
      expect(body['events'], isA<List>());

      final events = body['events'] as List;
      expect(events, hasLength(3));

      for (final ev in events) {
        final map = ev as Map<String, dynamic>;
        expect(map.containsKey('name'), isTrue);
        expect(map.containsKey('type'), isFalse);
        expect(map.containsKey('anonId'), isFalse);
        expect(map['props'], isA<Map>());
        expect(map['ts'], ts);
      }

      expect(events[0]['name'], 'screen_view');
      expect((events[0]['props'] as Map)['screen'], '/chats');
      expect(events[1]['name'], 'feature_use');
      expect((events[1]['props'] as Map)['feature'], 'chat_send');
      expect(events[2]['name'], 'session_end');
      expect((events[2]['props'] as Map)['durationSec'], 120);
    });

    test('legacy queued rows with type + flat keys still wire correctly', () {
      const ts = '2026-09-03T10:00:00.000Z';
      final body = AnalyticsService.buildPostBody(
        anonId: 'legacy-anon-id',
        queued: [
          {'type': 'screen_view', 'screen': '/me', 'ts': ts},
        ],
      );
      final ev = (body['events'] as List).single as Map;
      expect(ev['name'], 'screen_view');
      expect((ev['props'] as Map)['screen'], '/me');
    });
  });
}
