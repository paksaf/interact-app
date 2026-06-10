// SPDX-License-Identifier: AGPL-3.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pin_code_fields/pin_code_fields.dart';

import '../../services/auth_service.dart';

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});
  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _phoneCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  bool _otpSent = false;
  bool _busy = false;
  String? _error;

  Future<void> _sendOtp() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authServiceProvider).requestOtp(_phoneCtrl.text.trim());
      setState(() => _otpSent = true);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // New AuthService API (2026-05-21) — verifyOtp uses the otpId
      // stashed internally by requestOtp(); only the user-typed code
      // is needed here.
      await ref.read(authServiceProvider).verifyOtp(_codeCtrl.text.trim());
      if (!mounted) return;
      // Land on /calls (default tab) per voice/video-first PRD,
      // not /home (the old standalone route — gone in INTERACT shell).
      context.go('/calls');
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.chat_bubble, size: 56, color: cs.primary),
                  const SizedBox(height: 12),
                  Text(
                    'INTERACT Talk',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _otpSent
                        ? 'Enter the 6-digit code we sent you'
                        : 'Sign in with your phone number',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: cs.outline),
                  ),
                  const SizedBox(height: 28),
                  if (!_otpSent) ...[
                    TextField(
                      controller: _phoneCtrl,
                      keyboardType: TextInputType.phone,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'Phone (with country code)',
                        hintText: '+923001234567',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _busy ? null : _sendOtp,
                      icon: const Icon(Icons.send),
                      label: const Text('Send code'),
                    ),
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
                      onPressed:
                          _busy ? null : () => setState(() => _otpSent = false),
                      child: const Text('Use a different number'),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: TextStyle(color: cs.error)),
                  ],
                  const SizedBox(height: 28),
                  Text(
                    'One identity across every INTERACT app — Sahulat, '
                    'Pro, FleetOps, BVI, Rewards, Grower OS.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11, color: cs.outline),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
