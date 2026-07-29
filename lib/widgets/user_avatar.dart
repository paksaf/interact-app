// SPDX-License-Identifier: AGPL-3.0
//
// UserAvatar — shows a profile picture (NetworkImage) when a URL is set,
// falling back to the initial letter on the brand color. Used across chats,
// the chat header, the Me card, and the incoming-call ring so people see
// each other's photo instead of just initials.
import 'package:flutter/material.dart';

class UserAvatar extends StatelessWidget {
  const UserAvatar({
    super.key,
    this.url,
    required this.name,
    this.radius = 20,
    this.background,
    this.foreground,
  });

  final String? url;
  final String name;
  final double radius;
  final Color? background;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasUrl = url != null && url!.trim().isNotEmpty;
    final initial =
        name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    return CircleAvatar(
      radius: radius,
      backgroundColor: background ?? cs.primary,
      backgroundImage: hasUrl ? NetworkImage(url!.trim()) : null,
      child: hasUrl
          ? null
          : Text(
              initial,
              style: TextStyle(
                color: foreground ?? cs.onPrimary,
                fontWeight: FontWeight.w700,
                fontSize: radius * 0.82,
              ),
            ),
    );
  }
}
