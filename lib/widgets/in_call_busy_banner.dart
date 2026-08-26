// SPDX-License-Identifier: AGPL-3.0
//
// Marks the session as on-call (second ringers get `busy`) and paints a
// gold banner when someone tries to call while this screen is up.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/call_signaling.dart';

class InCallBusyBanner extends ConsumerStatefulWidget {
  const InCallBusyBanner({super.key, this.top = 56});

  final double top;

  @override
  ConsumerState<InCallBusyBanner> createState() => _InCallBusyBannerState();
}

class _InCallBusyBannerState extends ConsumerState<InCallBusyBanner> {
  String? _text;
  CallSignaling? _signaling;

  @override
  void initState() {
    super.initState();
    _signaling = ref.read(callSignalingProvider);
    _signaling!.setInCall(true);
    _signaling!.missedWhileBusy.addListener(_onMissed);
  }

  void _onMissed() {
    final call = _signaling?.missedWhileBusy.value;
    if (call == null || !mounted) return;
    setState(() {
      _text = '${call.callerName} tried to call — marked busy';
    });
    Future<void>.delayed(const Duration(seconds: 8), () {
      if (!mounted) return;
      _signaling?.clearMissedWhileBusy();
      setState(() => _text = null);
    });
  }

  @override
  void dispose() {
    try {
      _signaling?.missedWhileBusy.removeListener(_onMissed);
      _signaling?.setInCall(false);
    } catch (_) {/* provider may already be gone */}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = _text;
    if (text == null) return const SizedBox.shrink();
    return Positioned(
      top: widget.top,
      left: 16,
      right: 16,
      child: Semantics(
        liveRegion: true,
        label: text,
        child: Material(
          color: const Color(0xFFBE9A5F),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                const Icon(Icons.phone_missed,
                    color: Color(0xFF12253F), size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    text,
                    style: const TextStyle(
                      color: Color(0xFF12253F),
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
