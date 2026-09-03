// SPDX-License-Identifier: AGPL-3.0
//
// Help book — a searchable, offline guide to INTERACT's features. Type a
// question ("how do I use walkie talkie") to get a direct answer, or browse
// features by category.
import 'package:flutter/material.dart';

import 'help_content.dart';
import 'help_knowledge.dart';

class HelpScreen extends StatefulWidget {
  const HelpScreen({super.key});
  @override
  State<HelpScreen> createState() => _HelpScreenState();
}

class _HelpScreenState extends State<HelpScreen> {
  final _q = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final searching = _query.trim().isNotEmpty;
    final results = searching ? HelpKnowledge.search(_query) : const <HelpArticle>[];

    return Scaffold(
      appBar: AppBar(title: const Text('Help')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                controller: _q,
                textInputAction: TextInputAction.search,
                onChanged: (v) => setState(() => _query = v),
                decoration: InputDecoration(
                  hintText: 'Ask how to use a feature…',
                  prefixIcon: const Icon(Icons.help_outline),
                  suffixIcon: searching
                      ? IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () => setState(() {
                            _q.clear();
                            _query = '';
                          }),
                        )
                      : null,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            Expanded(
              child: searching
                  ? _results(cs, results)
                  : _browse(cs),
            ),
          ],
        ),
      ),
    );
  }

  Widget _results(ColorScheme cs, List<HelpArticle> results) {
    if (results.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            "No guide matched that. Try a feature name like “townhall”, "
            "“walkie talkie”, “offline”, “notes” or “backup”.",
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.outline),
          ),
        ),
      );
    }
    final top = results.first;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        Card(
          color: cs.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Answer',
                    style: TextStyle(
                        color: cs.onPrimaryContainer,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                        letterSpacing: 1)),
                const SizedBox(height: 6),
                Text(HelpKnowledge.answer(_query),
                    style: TextStyle(color: cs.onPrimaryContainer, height: 1.4)),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => _open(top),
                    child: const Text('Open full guide'),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (results.length > 1) ...[
          const SizedBox(height: 8),
          Text('Related', style: Theme.of(context).textTheme.labelLarge),
          for (final a in results.skip(1).take(4)) _tile(cs, a),
        ],
      ],
    );
  }

  Widget _browse(ColorScheme cs) {
    final groups = HelpKnowledge.byCategory();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        for (final entry in groups.entries) ...[
          Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 4),
            child: Text(entry.key,
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(color: cs.primary)),
          ),
          for (final a in entry.value) _tile(cs, a),
        ],
      ],
    );
  }

  Widget _tile(ColorScheme cs, HelpArticle a) => Card(
        margin: const EdgeInsets.symmetric(vertical: 4),
        child: ListTile(
          title: Text(a.title),
          subtitle: Text(a.summary,
              maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _open(a),
        ),
      );

  void _open(HelpArticle a) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => HelpArticleScreen(article: a)),
    );
  }
}

class HelpArticleScreen extends StatelessWidget {
  const HelpArticleScreen({super.key, required this.article});
  final HelpArticle article;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(article.title)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(article.category.toUpperCase(),
                style: TextStyle(
                    color: cs.primary,
                    fontSize: 12,
                    letterSpacing: 1,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(article.summary,
                style: const TextStyle(fontSize: 16, height: 1.5)),
            if (article.steps.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text('Steps',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              for (var i = 0; i < article.steps.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CircleAvatar(
                        radius: 12,
                        backgroundColor: cs.primaryContainer,
                        child: Text('${i + 1}',
                            style: TextStyle(
                                fontSize: 12,
                                color: cs.onPrimaryContainer)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(article.steps[i],
                            style: const TextStyle(height: 1.4)),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
