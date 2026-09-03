// SPDX-License-Identifier: AGPL-3.0
//
// Calls — default landing tab. Presents the polished welcome hub (voice-first
// AI, primary nav, cross-app chips). Classic call actions live in the welcome
// home sheet and the Calls nav tile.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../widgets/welcome/welcome_screen.dart';

class CallsTab extends ConsumerWidget {
  const CallsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const Scaffold(
      backgroundColor: Colors.transparent,
      body: WelcomeScreen(),
    );
  }
}
