// SPDX-License-Identifier: AGPL-3.0
//
// Canonical share / deep-link URLs for Talk SocialReels.

const talkWebHost = 'talk.interactpak.com';

/// HTTPS App Link + web fallback for a server SocialReel row.
String talkReelShareUrl(String reelId) =>
    'https://$talkWebHost/reel/$reelId';

/// Custom scheme when the caller knows Talk is installed.
String talkReelDeepLink(String reelId) => 'interact://talk/reel/$reelId';
