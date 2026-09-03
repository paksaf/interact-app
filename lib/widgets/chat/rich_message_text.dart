// SPDX-License-Identifier: AGPL-3.0

import 'package:flutter/material.dart';

import '../../core/chat/message_markup.dart';

/// Renders chat message body with inline markup, falling back to plain text.
class RichMessageText extends StatelessWidget {
  const RichMessageText({
    super.key,
    required this.text,
    required this.style,
    this.maxLines,
    this.overflow,
    this.textAlign,
  });

  final String text;
  final TextStyle style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    if (!hasMessageMarkup(text)) {
      return Text(
        text,
        style: style,
        maxLines: maxLines,
        overflow: overflow,
        textAlign: textAlign,
      );
    }
    return Text.rich(
      TextSpan(children: parseMessageMarkupSpans(text, baseStyle: style)),
      maxLines: maxLines,
      overflow: overflow ?? TextOverflow.clip,
      textAlign: textAlign,
    );
  }
}

/// Plain-text preview for reply quotes and list subtitles.
String messagePlainPreview(String body) {
  final stripped = stripMessageMarkup(body).trim();
  return stripped.isEmpty ? body.trim() : stripped;
}
