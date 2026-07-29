// SPDX-License-Identifier: AGPL-3.0
//
// Multi-channel sign-in (Weather / Lifestyle pattern): pick SMS, WhatsApp,
// or Email first, then enter phone/email and OTP. Fail-safe: never advance
// to the code screen on decoy / undelivered responses from interactpak.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pin_code_fields/pin_code_fields.dart';

import '../../services/auth_service.dart';
import '../../utils/phone_normalize.dart';

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({
    super.key,
    this.sessionExpired = false,
    this.prefillPhone,
  });

  final bool sessionExpired;
  final String? prefillPhone;

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  // Shared focus for the phone/email field (only one is shown at a time).
  // We request focus explicitly after a channel is picked because MIUI often
  // ignores `autofocus` when a field is remounted, leaving the keyboard hidden.
  final _inputFocus = FocusNode();

  /// null = channel picker.
  String? _channel; // 'sms' | 'whatsapp' | 'email'
  bool _otpSent = false;
  bool _busy = false;
  String? _error;
  String? _hint; // non-error guidance (e.g. normalized number)

  bool get _isEmail => _channel == 'email';

  @override
  void initState() {
    super.initState();
    final p = widget.prefillPhone?.trim();
    if (p != null && p.isNotEmpty) {
      _phoneCtrl.text = p;
      _channel = 'sms';
    }
  }

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _codeCtrl.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  String get _channelLabel => switch (_channel) {
        'whatsapp' => 'WhatsApp',
        'email' => 'Email',
        'sms' => 'SMS',
        _ => 'code',
      };

  void _dismissKeyboard() {
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _pickChannel(String channel) {
    // MIUI often keeps the previous (phone) keyboard if we only swap
    // keyboardType on a focused field — unfocus + remount via ValueKey, then
    // explicitly re-request focus once the new field is in the tree so the
    // correct keyboard actually pops up (autofocus alone is unreliable here).
    _dismissKeyboard();
    setState(() {
      _channel = channel;
      _otpSent = false;
      _error = null;
      _hint = null;
      _codeCtrl.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_otpSent) _inputFocus.requestFocus();
    });
  }

  void _backToChannels() {
    _dismissKeyboard();
    setState(() {
      _channel = null;
      _otpSent = false;
      _error = null;
      _hint = null;
      _codeCtrl.clear();
    });
  }

  Future<void> _sendOtp() async {
    final channel = _channel;
    if (channel == null) return;

    _dismissKeyboard();
    setState(() {
      _busy = true;
      _error = null;
      _hint = null;
    });

    try {
      // Normalize phone in the field so the user sees E.164.
      if (!_isEmail) {
        final e164 = normalizeInteractPhone(_phoneCtrl.text);
        if (e164 != null && e164 != _phoneCtrl.text.trim()) {
          _phoneCtrl.text = e164;
          _hint = 'Using $e164';
        }
      }

      final identifier =
          (_isEmail ? _emailCtrl.text : _phoneCtrl.text).trim();
      if (identifier.isEmpty) {
        setState(() => _error = _isEmail
            ? 'Enter your email address'
            : 'Enter your phone number');
        return;
      }

      final result = await ref
          .read(authServiceProvider)
          .requestOtp(identifier, channel: channel);

      if (!mounted) return;

      if (result.isDecoy) {
        setState(() {
          _otpSent = false;
          _error =
              'Couldn’t start sign-up for “$identifier” just now.\n\n'
              '• Double-check the number/email and try again\n'
              '• Or try another channel (SMS / WhatsApp / Email)';
        });
        return;
      }

      if (!result.delivered) {
        setState(() {
          _otpSent = false;
          _error =
              'Could not deliver via $_channelLabel'
              '${result.provider != null ? ' (${result.provider})' : ''}.\n\n'
              'Try WhatsApp or Email instead.';
        });
        return;
      }

      setState(() {
        _otpSent = true;
        _hint =
            'Code sent via $_channelLabel. Check spam if using email.';
      });
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final auth = ref.read(authServiceProvider);
      await auth.verifyOtp(_codeCtrl.text.trim());
      final isNew = await auth.consumeJustCreated();
      if (!mounted) return;
      // First-time users build their profile before landing in the app.
      context.go(isNew ? '/profile-setup' : '/calls');
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _dismissKeyboard,
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              keyboardDismissBehavior:
                  ScrollViewKeyboardDismissBehavior.onDrag,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                    Icon(Icons.forum_rounded, size: 56, color: cs.primary),
                    const SizedBox(height: 12),
                    Text(
                      'INTERACT',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _otpSent
                          ? 'Enter the 6-digit code sent via $_channelLabel'
                          : _channel == null
                              ? 'Sign in — choose how to get your code'
                              : 'Send code via $_channelLabel',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: cs.outline),
                    ),
                    if (widget.sessionExpired) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: cs.tertiaryContainer.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          'Session expired (8h login). Your number is saved — '
                          'request a new code.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: cs.onTertiaryContainer,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    if (_channel == null) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        margin: const EdgeInsets.only(bottom: 16),
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          'New here? Just pick a channel and enter your number '
                          'or email — we’ll text you a code and set up your '
                          'account. No sign-up form needed.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                      _ChannelTile(
                        icon: Icons.chat_outlined,
                        title: 'WhatsApp',
                        subtitle: 'Fastest in Pakistan — recommended',
                        highlighted: true,
                        onTap: () => _pickChannel('whatsapp'),
                      ),
                      _ChannelTile(
                        icon: Icons.sms_outlined,
                        title: 'SMS',
                        subtitle: 'Code by text message',
                        onTap: () => _pickChannel('sms'),
                      ),
                      _ChannelTile(
                        icon: Icons.mail_outline,
                        title: 'Email',
                        subtitle: 'Code to your inbox (check spam)',
                        onTap: () => _pickChannel('email'),
                      ),
                    ] else if (!_otpSent) ...[
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: _busy ? null : _backToChannels,
                          icon: const Icon(Icons.arrow_back, size: 18),
                          label: const Text('Change channel'),
                        ),
                      ),
                      const SizedBox(height: 4),
                      _isEmail
                          ? TextField(
                              // Remount when switching from phone → email so
                              // MIUI drops the numeric keypad (common stuck state).
                              key: const ValueKey('auth-email'),
                              controller: _emailCtrl,
                              focusNode: _inputFocus,
                              // emailAddress alone sticks on phone keypad on
                              // some MIUI builds after a phone field — use text.
                              keyboardType: TextInputType.text,
                              autofillHints: const [AutofillHints.email],
                              autocorrect: false,
                              enableSuggestions: false,
                              textCapitalization: TextCapitalization.none,
                              textInputAction: TextInputAction.send,
                              onSubmitted: (_) => _sendOtp(),
                              decoration: const InputDecoration(
                                labelText: 'Your email',
                                hintText: 'you@example.com',
                                prefixIcon: Icon(Icons.mail_outline),
                                border: OutlineInputBorder(),
                              ),
                            )
                          : TextField(
                              key: ValueKey('auth-phone-$_channel'),
                              controller: _phoneCtrl,
                              focusNode: _inputFocus,
                              keyboardType: TextInputType.phone,
                              textInputAction: TextInputAction.send,
                              onSubmitted: (_) => _sendOtp(),
                              inputFormatters: [
                                FilteringTextInputFormatter.allow(
                                  RegExp(r'[0-9+\s\-()]'),
                                ),
                              ],
                              decoration: InputDecoration(
                                labelText: 'Your phone number',
                                hintText: '03XXXXXXXXX or +923XXXXXXXXX',
                                helperText:
                                    'We’ll send a one-time code to this number',
                                prefixIcon: Icon(
                                  _channel == 'whatsapp'
                                      ? Icons.chat_outlined
                                      : Icons.phone_outlined,
                                ),
                                border: const OutlineInputBorder(),
                              ),
                            ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _busy ? null : _sendOtp,
                        icon: _busy
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Icon(_channel == 'whatsapp'
                                ? Icons.chat_outlined
                                : Icons.send),
                        label: Text('Send code via $_channelLabel'),
                      ),
                      if (!_isEmail) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 8,
                          children: [
                            if (_channel != 'whatsapp')
                              TextButton(
                                onPressed: _busy
                                    ? null
                                    : () {
                                        _pickChannel('whatsapp');
                                      },
                                child: const Text('Try WhatsApp'),
                              ),
                            if (_channel != 'sms')
                              TextButton(
                                onPressed:
                                    _busy ? null : () => _pickChannel('sms'),
                                child: const Text('Try SMS'),
                              ),
                            TextButton(
                              onPressed:
                                  _busy ? null : () => _pickChannel('email'),
                              child: const Text('Try Email'),
                            ),
                          ],
                        ),
                      ],
                    ] else ...[
                      PinCodeTextField(
                        appContext: context,
                        controller: _codeCtrl,
                        length: 6,
                        onChanged: (_) {},
                        keyboardType: TextInputType.number,
                        animationType: AnimationType.fade,
                        pinTheme: PinTheme(
                          shape: PinCodeFieldShape.box,
                          borderRadius: BorderRadius.circular(8),
                          fieldHeight: 44,
                          fieldWidth: 38,
                          activeColor: cs.primary,
                          selectedColor: cs.primary,
                          inactiveColor: cs.outlineVariant,
                        ),
                      ),
                      const SizedBox(height: 8),
                      FilledButton.icon(
                        onPressed: _busy ? null : _verify,
                        icon: const Icon(Icons.lock_open),
                        label: const Text('Verify + continue'),
                      ),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() {
                                  _otpSent = false;
                                  _error = null;
                                  _hint = null;
                                }),
                        child: const Text('Resend / change number'),
                      ),
                      TextButton(
                        onPressed: _busy ? null : _backToChannels,
                        child: const Text('Use a different channel'),
                      ),
                    ],
                    if (_hint != null && _error == null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _hint!,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: cs.primary, fontSize: 13),
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: cs.errorContainer.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: cs.onErrorContainer,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 28),
                    Text(
                      'Free, private, voice-first messaging. Sign in with your '
                      'phone, WhatsApp, or email.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11, color: cs.outline),
                    ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ChannelTile extends StatelessWidget {
  const _ChannelTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.highlighted = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: highlighted ? cs.primaryContainer.withValues(alpha: 0.45) : null,
      child: ListTile(
        leading: Icon(icon, color: highlighted ? cs.primary : null),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
