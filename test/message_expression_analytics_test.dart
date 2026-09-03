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
        {'type': 'screen_view', 'screen': '/chats', 'ts': old},
        {
          'type': 'screen_view',
          'screen': '/calls',
          'ts': DateTime.utc(2026, 9, 3).toIso8601String(),
        },
      ], nowMs: now);
      expect(trimmed, hasLength(1));
      expect(trimmed.single['screen'], '/calls');
    });
  });
}
