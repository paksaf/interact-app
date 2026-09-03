// SPDX-License-Identifier: AGPL-3.0
//
// In-app help knowledge base. Authored as Dart (not a loaded asset) so it is
// compile-checked and always available OFFLINE. The same content grounds the
// online AI assistant server-side, so answers match the help book.
class HelpArticle {
  const HelpArticle({
    required this.id,
    required this.title,
    required this.category,
    required this.keywords,
    required this.summary,
    required this.steps,
  });

  final String id;
  final String title;
  final String category;
  final List<String> keywords;
  final String summary;
  final List<String> steps;

  String get searchText =>
      '$title $summary ${keywords.join(' ')} ${steps.join(' ')}'.toLowerCase();
}

const List<HelpArticle> helpArticles = <HelpArticle>[
  HelpArticle(
    id: 'townhall',
    title: 'Host or join a townhall meeting',
    category: 'Meetings & calls',
    keywords: ['townhall', 'meeting', 'live', 'room', 'webinar', 'conference', 'host', 'speaker'],
    summary:
        'Townhalls are large, multi-party live rooms (audio/video) backed by the '
        'server, so many people can join at once. The host starts a room and shares '
        'its code; attendees join with that code.',
    steps: [
      'From the home screen, start a new live/townhall room as host.',
      'Share the room code (or link) with attendees.',
      'Attendees tap Join with code, enter the 6-character code, and join.',
      'As host, use the control bar to mute/remove speakers or promote moderators.',
      'To let people without the app join, open Guests and pick Passcode or Waiting room.',
    ],
  ),
  HelpArticle(
    id: 'guest-join',
    title: 'Let guests join without the app',
    category: 'Meetings & calls',
    keywords: ['guest', 'browser', 'no app', 'link', 'passcode', 'waiting room', 'external', 'invite'],
    summary:
        'A townhall host can let people join from a web browser — no app or account '
        'needed. Choose Passcode (link + code, instant) or Waiting room (you admit '
        'each guest).',
    steps: [
      'Start your townhall as host.',
      'Tap the Guests button in the control bar.',
      'Pick Off, Passcode, or Waiting room. For Passcode, set a 4-64 character code.',
      'Copy or share the guest link that appears.',
      'Guests open the link in any browser, enter their name (and passcode), and join.',
      'In Waiting-room mode, admit or deny each guest from the side panel.',
    ],
  ),
  HelpArticle(
    id: 'calls',
    title: 'Make a voice or video call',
    category: 'Meetings & calls',
    keywords: ['call', 'voice', 'video', 'ring', 'dial', 'phone'],
    summary:
        'Start a one-to-one or group voice/video call from any chat. The other '
        'person rings and can accept or decline.',
    steps: [
      'Open a chat with the person or group.',
      'Tap the video or phone icon in the top bar.',
      'Wait for them to accept; use the on-call controls to mute, switch camera, or hang up.',
    ],
  ),
  HelpArticle(
    id: 'walkie-talkie',
    title: 'Use walkie-talkie (push-to-talk)',
    category: 'Offline & radio',
    keywords: ['walkie', 'walkie-talkie', 'ptt', 'push to talk', 'radio', 'lan', 'ble', 'bluetooth', 'wifi', 'mesh'],
    summary:
        'Walkie-talkie is instant push-to-talk. It can run over the internet, over '
        'the local Wi-Fi/LAN with no internet, or over Bluetooth/mesh when there is '
        'no network at all - hold to talk, release to listen.',
    steps: [
      'Open the offline/comms hub from the home screen.',
      'Pick LAN walkie (same Wi-Fi, no internet) or BLE walkie (Bluetooth, no network).',
      'Everyone nearby on the same channel joins automatically.',
      'Press and hold the big button to talk; release to hear others.',
    ],
  ),
  HelpArticle(
    id: 'offline-iot',
    title: 'Offline & IoT communication (mesh, LoRa)',
    category: 'Offline & radio',
    keywords: ['offline', 'iot', 'lora', 'mesh', 'nearby', 'no internet', 'bridge', 'long range', 'radio'],
    summary:
        'When there is no cell or Wi-Fi, INTERACT can still pass messages device to '
        'device using a Bluetooth/Wi-Fi mesh between nearby phones, and reach much '
        'farther through a LoRa long-range radio bridge.',
    steps: [
      'Open the offline/comms hub from the home screen.',
      'Use Nearby mesh to relay chats and voice between phones that are close together.',
      'Add more phones to extend the mesh - each device relays for the next.',
      'For long distances with no network, connect a LoRa bridge to carry short messages over kilometres.',
      'Messages sync back to the internet automatically once any device regains a connection.',
    ],
  ),
  HelpArticle(
    id: 'chat',
    title: 'Chat: text, drawings, photos and reactions',
    category: 'Chat',
    keywords: ['chat', 'message', 'text', 'bold', 'draw', 'sign', 'photo', 'react', 'emoji', 'report'],
    summary:
        'Chats support rich text (bold/italic/underline/colour), hand-drawn sketches '
        'or signatures, photos and files, emoji reactions, and reporting a message.',
    steps: [
      'Open a chat and type in the composer; use the format bar for bold/italic/colour.',
      'Tap the attach button to add a photo, file, drawing/signature, or camera capture.',
      'Long-press a message to react with an emoji or to report it.',
      'Tap the back arrow (top-left) to return to your chats or home.',
    ],
  ),
  HelpArticle(
    id: 'notes',
    title: 'Notes with pen, photos and reminders',
    category: 'Productivity',
    keywords: ['note', 'notes', 'pen', 'handwriting', 'draw', 'photo', 'reminder', 'sketch'],
    summary:
        'Keep personal notes with typed text, a pen/handwriting sketch, or a photo '
        'you can crop and edit - and set a reminder that notifies you later.',
    steps: [
      'From the home hub, tap the Notes chip.',
      'Tap New note, then type, or use Draw/write for the pen, or Photo to capture and crop.',
      'Tap Set a reminder and pick a date and time to be notified.',
      'Save - the note and any reminder appear in your list.',
    ],
  ),
  HelpArticle(
    id: 'backup',
    title: 'Back up and restore your chats',
    category: 'Account & data',
    keywords: ['backup', 'restore', 'export', 'storage', 'encrypted', 'passphrase', 'cloud'],
    summary:
        'Your chats can be backed up as an encrypted blob so you can restore them on '
        'a new device. Only you hold the passphrase - the server never sees your '
        'plaintext.',
    steps: [
      'Open Backup from the menu.',
      'Set a passphrase you will remember (it cannot be recovered if lost).',
      'Back up now; to restore on a new device, sign in and enter the same passphrase.',
      'Need more space for media backups? Storage plans (Free/Plus/Pro/Max) will be available once payments are enabled.',
    ],
  ),
  HelpArticle(
    id: 'themes',
    title: 'Change theme and chat wallpaper',
    category: 'Personalise',
    keywords: ['theme', 'colour', 'dark', 'light', 'wallpaper', 'background', 'personalise', 'appearance'],
    summary:
        'Pick a colour theme and set a chat wallpaper (image, dimmed or blurred). '
        'Your choices sync across your devices.',
    steps: [
      'Open Settings then Theme to choose or customise a theme.',
      'Open Settings then Chat wallpaper to set a background image and adjust dim/blur.',
      'Changes sync to your other signed-in devices automatically.',
    ],
  ),
  HelpArticle(
    id: 'friends-map',
    title: 'Share location on the friends map',
    category: 'Location',
    keywords: ['map', 'location', 'friends', 'share', 'gps', 'zoom', 'offline map'],
    summary:
        'See yourself and people sharing with you on a live map that also works '
        'offline with downloaded tiles. Pinch or use the +/- buttons to zoom.',
    steps: [
      'Open the friends map from the home menu.',
      'Pinch to zoom, or use the + and - buttons on the right edge.',
      'Tap Fit everyone to frame all shared pins.',
      'Download this area for offline use before you lose signal.',
    ],
  ),
  HelpArticle(
    id: 'reels',
    title: 'Watch and post reels',
    category: 'Discover',
    keywords: ['reel', 'reels', 'video', 'youtube', 'tiktok', 'post', 'share'],
    summary:
        'Reels are short videos on your rail. You can add your own from a local '
        'clip or by pasting a YouTube, TikTok or X link.',
    steps: [
      'Open the reels rail on the home screen and swipe through.',
      'Tap add and paste a YouTube/TikTok/X link, or pick a local clip.',
      'Like, comment or share reels; report anything inappropriate.',
    ],
  ),
  HelpArticle(
    id: 'zeka',
    title: 'Zeka - calculate your Zakat',
    category: 'Tools',
    keywords: ['zeka', 'zakat', 'calculator', 'nisab', 'charity', 'convert'],
    summary:
        'Zeka is INTERACT Zakat toolkit - work out what is due with the calculator '
        'and converter.',
    steps: [
      'From the home hub, tap the Zeka chip.',
      'Enter your assets to calculate Zakat, or use the converter for values.',
    ],
  ),
  HelpArticle(
    id: 'getting-started',
    title: 'Sign in and set up your profile',
    category: 'Getting started',
    keywords: ['sign in', 'login', 'register', 'profile', 'username', 'handle', 'setup', 'qr'],
    summary:
        'Sign in with your phone/OTP or by approving on another device, then set '
        'your name and a unique username that no one else can take.',
    steps: [
      'Open the app and sign in (phone OTP, or approve from a device already signed in).',
      'Set your display name and pick a username - usernames are reserved to you.',
      'Add a profile photo, then start a chat or join a meeting.',
    ],
  ),
];
