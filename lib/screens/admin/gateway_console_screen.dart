// SPDX-License-Identifier: AGPL-3.0
//
// GatewayConsoleScreen — in-app embed of the multi-country OTP Gateway
// Console (https://gateways.interactpak.com), so a manager can re-link a
// WhatsApp line (QR or pairing code) or check SMS health from the phone,
// without SSH, when Twilio / capcom6 fail for a country.
//
// The console itself sits behind Caddy HTTP Basic auth (admin login), so
// this screen embeds the site and forwards the Basic-auth challenge to a
// native dialog. Credentials are optionally remembered in
// flutter_secure_storage (already a project dep) so a manager types them
// once per device. Nothing is hard-coded into the app — the Basic-auth
// admin password is the real gate, exactly as on the web.
//
// Added 2026-09-02. url_launcher already ships a "open in browser" escape
// hatch in the app bar as a fallback if the WebView misbehaves on a device.
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../widgets/branded_app_bar.dart';

class GatewayConsoleScreen extends StatefulWidget {
  const GatewayConsoleScreen({super.key});

  static const String consoleUrl = 'https://gateways.interactpak.com';

  @override
  State<GatewayConsoleScreen> createState() => _GatewayConsoleScreenState();
}

class _GatewayConsoleScreenState extends State<GatewayConsoleScreen> {
  static const _kUserKey = 'gateway_console_basic_user';
  static const _kPassKey = 'gateway_console_basic_pass';
  final _secure = const FlutterSecureStorage();

  late final WebViewController _controller;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted) {
              setState(() {
                _loading = true;
                _error = null;
              });
            }
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _loading = false);
          },
          onHttpAuthRequest: _onAuthRequest,
          onWebResourceError: (err) {
            // Sub-resource errors fire this too; only surface main-frame ones.
            if (err.isForMainFrame == false) return;
            if (mounted) {
              setState(() {
                _loading = false;
                _error = err.description;
              });
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(GatewayConsoleScreen.consoleUrl));
  }

  Future<void> _onAuthRequest(HttpAuthRequest request) async {
    final savedUser = await _secure.read(key: _kUserKey);
    final savedPass = await _secure.read(key: _kPassKey);

    // If we already have creds, answer the challenge silently the first time.
    if (savedUser != null && savedPass != null) {
      request.onProceed(
        WebViewCredential(user: savedUser, password: savedPass),
      );
      return;
    }
    if (!mounted) {
      request.onCancel();
      return;
    }
    final creds = await _promptForCredentials(host: request.host);
    if (creds == null) {
      request.onCancel();
      return;
    }
    if (creds.remember) {
      await _secure.write(key: _kUserKey, value: creds.user);
      await _secure.write(key: _kPassKey, value: creds.password);
    }
    request.onProceed(
      WebViewCredential(user: creds.user, password: creds.password),
    );
  }

  Future<_Creds?> _promptForCredentials({required String host}) {
    final userCtl = TextEditingController();
    final passCtl = TextEditingController();
    var remember = true;
    return showDialog<_Creds>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Admin login'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Sign in to the Gateway Console ($host).',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: userCtl,
                autofocus: true,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Username',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: passCtl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Password',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                value: remember,
                onChanged: (v) => setLocal(() => remember = v ?? false),
                title: const Text('Remember on this phone'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(
                _Creds(
                  user: userCtl.text.trim(),
                  password: passCtl.text,
                  remember: remember,
                ),
              ),
              child: const Text('Sign in'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _forgetLogin() async {
    await _secure.delete(key: _kUserKey);
    await _secure.delete(key: _kPassKey);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved admin login cleared')),
      );
    }
  }

  Future<void> _openInBrowser() async {
    final uri = Uri.parse(GatewayConsoleScreen.consoleUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _reload() {
    setState(() {
      _loading = true;
      _error = null;
    });
    _controller.reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: BrandedAppBar(
        title: 'Gateway Console',
        subtitle: 'WhatsApp + SMS re-link',
        actions: [
          IconButton(
            tooltip: 'Reload',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _reload,
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'browser') _openInBrowser();
              if (v == 'forget') _forgetLogin();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'browser',
                child: Text('Open in browser'),
              ),
              PopupMenuItem(
                value: 'forget',
                child: Text('Clear saved login'),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Stack(
          children: [
            if (_error == null)
              WebViewWidget(controller: _controller)
            else
              _ErrorView(message: _error!, onRetry: _reload),
            if (_loading && _error == null)
              const Center(child: CircularProgressIndicator()),
          ],
        ),
      ),
    );
  }
}

class _Creds {
  const _Creds({
    required this.user,
    required this.password,
    required this.remember,
  });
  final String user;
  final String password;
  final bool remember;
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded, size: 48, color: cs.error),
            const SizedBox(height: 12),
            Text(
              "Couldn't reach the Gateway Console",
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              message,
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
