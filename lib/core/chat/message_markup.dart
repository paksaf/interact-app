// SPDX-License-Identifier: AGPL-3.0
//
// Lightweight inline markup for chat bodies. Stored as plain UTF-8 so E2E
// encryption treats it like any text — no HTML, no structured JSON sidecar.
//
// Tags: {b} {i} {u} {s} {c:RRGGBB} with matching {/tag} closers.

import 'package:flutter/material.dart';

/// Remove markup tags, keeping inner text (for TTS, previews, notifications).
String stripMessageMarkup(String input) {
  if (input.isEmpty) return input;
  return input.replaceAll(
    RegExp(r'\{/?(?:b|i|u|s|c(?::[0-9A-Fa-f]{6})?)\}'),
    '',
  );
}

/// True when [input] contains recognized markup tags.
bool hasMessageMarkup(String input) {
  return RegExp(r'\{(?:b|i|u|s|c:[0-9A-Fa-f]{6})\}').hasMatch(input);
}

class _StyleFrame {
  _StyleFrame({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strikethrough = false,
    this.color,
  });

  final bool bold;
  final bool italic;
  final bool underline;
  final bool strikethrough;
  final Color? color;

  TextStyle apply(TextStyle base) {
    return base.copyWith(
      fontWeight: bold ? FontWeight.w700 : base.fontWeight,
      fontStyle: italic ? FontStyle.italic : base.fontStyle,
      decoration: _decoration(base.decoration),
      color: color ?? base.color,
    );
  }

  TextDecoration? _decoration(TextDecoration? existing) {
    final parts = <TextDecoration>[];
    if (underline) parts.add(TextDecoration.underline);
    if (strikethrough) parts.add(TextDecoration.lineThrough);
    if (parts.isEmpty) return existing;
    return TextDecoration.combine(parts);
  }
}

/// Parse [text] into [TextSpan]s using [baseStyle] as the default.
List<InlineSpan> parseMessageMarkupSpans(
  String text, {
  required TextStyle baseStyle,
}) {
  if (text.isEmpty) return const [];
  final tagRe = RegExp(r'\{(/?)(b|i|u|s|c(?::([0-9A-Fa-f]{6}))?)\}');
  final stack = <_StyleFrame>[_StyleFrame()];
  final spans = <InlineSpan>[];
  var last = 0;

  TextStyle currentStyle() => stack.last.apply(baseStyle);

  for (final m in tagRe.allMatches(text)) {
    if (m.start > last) {
      spans.add(TextSpan(
        text: text.substring(last, m.start),
        style: currentStyle(),
      ));
    }
    final closing = m.group(1) == '/';
    final tag = m.group(2)!;
    if (closing) {
      if (stack.length > 1) stack.removeLast();
    } else if (tag.startsWith('c')) {
      final hex = m.group(3);
      Color? c;
      if (hex != null && hex.length == 6) {
        final v = int.tryParse(hex, radix: 16);
        if (v != null) c = Color(0xFF000000 | v);
      }
      stack.add(_StyleFrame(
        bold: stack.last.bold,
        italic: stack.last.italic,
        underline: stack.last.underline,
        strikethrough: stack.last.strikethrough,
        color: c ?? stack.last.color,
      ));
    } else {
      stack.add(_StyleFrame(
        bold: tag == 'b' ? true : stack.last.bold,
        italic: tag == 'i' ? true : stack.last.italic,
        underline: tag == 'u' ? true : stack.last.underline,
        strikethrough: tag == 's' ? true : stack.last.strikethrough,
        color: stack.last.color,
      ));
    }
    last = m.end;
  }
  if (last < text.length) {
    spans.add(TextSpan(text: text.substring(last), style: currentStyle()));
  }
  return spans;
}

/// Insert [openTag]…[closeTag] around the current selection in [controller].
void wrapComposerSelection(
  TextEditingController controller, {
  required String openTag,
  required String closeTag,
}) {
  final sel = controller.selection;
  if (!sel.isValid) return;
  final text = controller.text;
  final start = sel.start.clamp(0, text.length);
  final end = sel.end.clamp(0, text.length);
  final selected = text.substring(start, end);
  final next = '${text.substring(0, start)}$openTag$selected$closeTag${text.substring(end)}';
  controller.value = TextEditingValue(
    text: next,
    selection: TextSelection.collapsed(
      offset: start + openTag.length + selected.length + closeTag.length,
    ),
  );
}

/// Insert [snippet] at the cursor (emoji or tag).
void insertAtComposerCursor(TextEditingController controller, String snippet) {
  final sel = controller.selection;
  final text = controller.text;
  final pos = sel.isValid ? sel.start.clamp(0, text.length) : text.length;
  final next = text.substring(0, pos) + snippet + text.substring(pos);
  controller.value = TextEditingValue(
    text: next,
    selection: TextSelection.collapsed(offset: pos + snippet.length),
  );
}
