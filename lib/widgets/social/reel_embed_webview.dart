// SPDX-License-Identifier: AGPL-3.0
//
// Renders TikTok / X oEmbed HTML inside the reels viewer (no client API keys).

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class ReelEmbedWebView extends StatefulWidget {
  const ReelEmbedWebView({
    super.key,
    required this.embedHtml,
    this.baseUrl = 'https://www.tiktok.com',
  });

  final String embedHtml;
  final String baseUrl;

  @override
  State<ReelEmbedWebView> createState() => _ReelEmbedWebViewState();
}

class _ReelEmbedWebViewState extends State<ReelEmbedWebView> {
  late final WebViewController _controller;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    final html = '''
<!DOCTYPE html>
<html>
<head>
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0">
<style>
  html, body { margin: 0; padding: 0; background: #000; height: 100%; }
  body { display: flex; align-items: center; justify-content: center; }
</style>
</head>
<body>${widget.embedHtml}</body>
</html>
''';
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (mounted) setState(() => _loading = false);
          },
        ),
      )
      ..loadHtmlString(html, baseUrl: widget.baseUrl);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        WebViewWidget(controller: _controller),
        if (_loading)
          const Center(
            child: CircularProgressIndicator(color: Colors.white54),
          ),
      ],
    );
  }
}
