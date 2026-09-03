// SPDX-License-Identifier: AGPL-3.0
//
// Renders TikTok / X oEmbed HTML inside the reels viewer (no client API keys).

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
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

  static bool _isAllowedEmbedNavigation(Uri uri, String baseUrl) {
    if (uri.scheme == 'about' || uri.scheme == 'data') return true;
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;

    final host = uri.host.toLowerCase();
    final baseHost = Uri.tryParse(baseUrl)?.host.toLowerCase() ?? '';
    if (baseHost.isNotEmpty &&
        (host == baseHost || host.endsWith('.$baseHost'))) {
      return true;
    }

    const allowed = {
      'www.tiktok.com',
      'tiktok.com',
      'm.tiktok.com',
      'vm.tiktok.com',
      'twitter.com',
      'www.twitter.com',
      'mobile.twitter.com',
      'x.com',
      'www.x.com',
      'platform.twitter.com',
      'cdn.syndication.twimg.com',
      'pbs.twimg.com',
    };
    if (allowed.contains(host)) return true;
    if (host.endsWith('.tiktok.com') || host.endsWith('.twimg.com')) {
      return true;
    }
    return false;
  }

  Future<void> _openExternally(Uri uri) async {
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

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
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            if (uri == null) return NavigationDecision.prevent;
            if (!request.isMainFrame) {
              return NavigationDecision.navigate;
            }
            if (_isAllowedEmbedNavigation(uri, widget.baseUrl)) {
              return NavigationDecision.navigate;
            }
            _openExternally(uri);
            return NavigationDecision.prevent;
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
