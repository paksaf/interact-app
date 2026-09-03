// SPDX-License-Identifier: AGPL-3.0
//
// Offline help retrieval. Ranks the bundled help articles against a natural-
// language question so the Help book search and the offline "how do I..."
// answers work with no network and no on-device LLM.
import 'help_content.dart';

class HelpKnowledge {
  const HelpKnowledge._();

  static final List<String> _stop = <String>[
    'how', 'do', 'i', 'to', 'the', 'a', 'an', 'is', 'can', 'use', 'my', 'in',
    'on', 'of', 'and', 'or', 'for', 'with', 'what', 'app', 'me', 'you', 'it',
  ];

  static List<String> _terms(String query) => query
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\s-]'), ' ')
      .split(RegExp(r'\s+'))
      .where((t) => t.length > 1 && !_stop.contains(t))
      .toList();

  /// Articles ranked by relevance to [query] (best first); empty if none.
  static List<HelpArticle> search(String query) {
    final terms = _terms(query);
    if (terms.isEmpty) return const [];
    final scored = <MapEntry<HelpArticle, int>>[];
    for (final a in helpArticles) {
      final title = a.title.toLowerCase();
      final text = a.searchText;
      var score = 0;
      for (final t in terms) {
        if (a.keywords.any((k) => k.toLowerCase() == t)) score += 5;
        if (title.contains(t)) score += 3;
        if (a.keywords.any((k) => k.toLowerCase().contains(t))) score += 2;
        if (text.contains(t)) score += 1;
      }
      if (score > 0) scored.add(MapEntry(a, score));
    }
    scored.sort((x, y) => y.value.compareTo(x.value));
    return scored.map((e) => e.key).toList();
  }

  static HelpArticle? best(String query) {
    final r = search(query);
    return r.isEmpty ? null : r.first;
  }

  /// A plain-text answer for an offline "how do I…" question.
  static String answer(String query) {
    final a = best(query);
    if (a == null) {
      return "I don't have a guide for that yet. Open Help to browse all "
          "features, or try rephrasing your question.";
    }
    final b = StringBuffer()
      ..writeln(a.title)
      ..writeln()
      ..writeln(a.summary);
    if (a.steps.isNotEmpty) {
      b.writeln();
      for (var i = 0; i < a.steps.length; i++) {
        b.writeln('${i + 1}. ${a.steps[i]}');
      }
    }
    return b.toString().trim();
  }

  /// Articles grouped by category, preserving first-seen category order.
  static Map<String, List<HelpArticle>> byCategory() {
    final map = <String, List<HelpArticle>>{};
    for (final a in helpArticles) {
      map.putIfAbsent(a.category, () => <HelpArticle>[]).add(a);
    }
    return map;
  }
}
