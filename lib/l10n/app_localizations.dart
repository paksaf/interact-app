import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_ar.dart';
import 'app_localizations_en.dart';
import 'app_localizations_pa.dart';
import 'app_localizations_ru.dart';
import 'app_localizations_tr.dart';
import 'app_localizations_ur.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('ar'),
    Locale('en'),
    Locale('pa'),
    Locale('ru'),
    Locale('tr'),
    Locale('ur')
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'INTERACT'**
  String get appTitle;

  /// No description provided for @tabCalls.
  ///
  /// In en, this message translates to:
  /// **'Calls'**
  String get tabCalls;

  /// No description provided for @tabChats.
  ///
  /// In en, this message translates to:
  /// **'Chats'**
  String get tabChats;

  /// No description provided for @tabContacts.
  ///
  /// In en, this message translates to:
  /// **'Contacts'**
  String get tabContacts;

  /// No description provided for @tabMe.
  ///
  /// In en, this message translates to:
  /// **'Me'**
  String get tabMe;

  /// No description provided for @languages.
  ///
  /// In en, this message translates to:
  /// **'Languages'**
  String get languages;

  /// No description provided for @languagesSubtitle.
  ///
  /// In en, this message translates to:
  /// **'EN · UR · AR · TR · RU · PA'**
  String get languagesSubtitle;

  /// No description provided for @languageSystem.
  ///
  /// In en, this message translates to:
  /// **'System default'**
  String get languageSystem;

  /// No description provided for @languageEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageEnglish;

  /// No description provided for @languageUrdu.
  ///
  /// In en, this message translates to:
  /// **'Urdu'**
  String get languageUrdu;

  /// No description provided for @languageArabic.
  ///
  /// In en, this message translates to:
  /// **'Arabic'**
  String get languageArabic;

  /// No description provided for @languageTurkish.
  ///
  /// In en, this message translates to:
  /// **'Turkish'**
  String get languageTurkish;

  /// No description provided for @languageRussian.
  ///
  /// In en, this message translates to:
  /// **'Russian'**
  String get languageRussian;

  /// No description provided for @languagePunjabi.
  ///
  /// In en, this message translates to:
  /// **'Punjabi'**
  String get languagePunjabi;

  /// No description provided for @chooseLanguage.
  ///
  /// In en, this message translates to:
  /// **'Choose language'**
  String get chooseLanguage;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @done.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get done;

  /// No description provided for @signInTitle.
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get signInTitle;

  /// No description provided for @signInSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Use your INTERACT phone or email — same login across every app.'**
  String get signInSubtitle;

  /// No description provided for @phoneOrEmail.
  ///
  /// In en, this message translates to:
  /// **'Phone or email'**
  String get phoneOrEmail;

  /// No description provided for @sendCode.
  ///
  /// In en, this message translates to:
  /// **'Send code'**
  String get sendCode;

  /// No description provided for @verifyCode.
  ///
  /// In en, this message translates to:
  /// **'Verify'**
  String get verifyCode;

  /// No description provided for @otpHint.
  ///
  /// In en, this message translates to:
  /// **'6-digit code'**
  String get otpHint;

  /// No description provided for @privateAiComingSoon.
  ///
  /// In en, this message translates to:
  /// **'Private AI (coming soon)'**
  String get privateAiComingSoon;

  /// No description provided for @privateAiOffSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Off — chat uses cloud (DeepSeek/Zeka). On-device toggle is stubbed.'**
  String get privateAiOffSubtitle;

  /// No description provided for @privateAiOnSubtitle.
  ///
  /// In en, this message translates to:
  /// **'On — blocked until on-device model ships (Phase 3).'**
  String get privateAiOnSubtitle;

  /// No description provided for @voiceNoteTranscription.
  ///
  /// In en, this message translates to:
  /// **'Voice note transcription'**
  String get voiceNoteTranscription;

  /// No description provided for @voiceNoteTranscriptionSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Cloud Whisper when OPENAI_API_KEY is set on Talk API'**
  String get voiceNoteTranscriptionSubtitle;

  /// No description provided for @onDeviceCapability.
  ///
  /// In en, this message translates to:
  /// **'On-device capability'**
  String get onDeviceCapability;

  /// No description provided for @backupRestore.
  ///
  /// In en, this message translates to:
  /// **'Backup & Restore'**
  String get backupRestore;

  /// No description provided for @backupSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Passphrase-encrypted archive of your chats'**
  String get backupSubtitle;

  /// No description provided for @communities.
  ///
  /// In en, this message translates to:
  /// **'Communities'**
  String get communities;

  /// No description provided for @communitiesSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Groups you own or belong to'**
  String get communitiesSubtitle;

  /// No description provided for @setUsername.
  ///
  /// In en, this message translates to:
  /// **'Set your @username'**
  String get setUsername;

  /// No description provided for @profilePhoto.
  ///
  /// In en, this message translates to:
  /// **'Profile photo'**
  String get profilePhoto;

  /// No description provided for @newChat.
  ///
  /// In en, this message translates to:
  /// **'New chat'**
  String get newChat;

  /// No description provided for @newChatSubtitle.
  ///
  /// In en, this message translates to:
  /// **'By phone, email, or @username'**
  String get newChatSubtitle;

  /// No description provided for @newGroup.
  ///
  /// In en, this message translates to:
  /// **'New group'**
  String get newGroup;

  /// No description provided for @newChannel.
  ///
  /// In en, this message translates to:
  /// **'New channel'**
  String get newChannel;

  /// No description provided for @newCommunity.
  ///
  /// In en, this message translates to:
  /// **'New community'**
  String get newCommunity;

  /// No description provided for @captions.
  ///
  /// In en, this message translates to:
  /// **'Captions'**
  String get captions;

  /// No description provided for @captionsUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Captions unavailable right now.'**
  String get captionsUnavailable;

  /// No description provided for @mute.
  ///
  /// In en, this message translates to:
  /// **'Mute'**
  String get mute;

  /// No description provided for @unmute.
  ///
  /// In en, this message translates to:
  /// **'Unmute'**
  String get unmute;

  /// No description provided for @cameraOn.
  ///
  /// In en, this message translates to:
  /// **'Camera on'**
  String get cameraOn;

  /// No description provided for @cameraOff.
  ///
  /// In en, this message translates to:
  /// **'Camera off'**
  String get cameraOff;

  /// No description provided for @shareScreen.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get shareScreen;

  /// No description provided for @stopShare.
  ///
  /// In en, this message translates to:
  /// **'Stop share'**
  String get stopShare;

  /// No description provided for @leave.
  ///
  /// In en, this message translates to:
  /// **'Leave'**
  String get leave;

  /// No description provided for @endCall.
  ///
  /// In en, this message translates to:
  /// **'End'**
  String get endCall;

  /// No description provided for @meetingSummary.
  ///
  /// In en, this message translates to:
  /// **'Meeting summary'**
  String get meetingSummary;

  /// No description provided for @summaryLanguage.
  ///
  /// In en, this message translates to:
  /// **'Summary language'**
  String get summaryLanguage;

  /// No description provided for @summarize.
  ///
  /// In en, this message translates to:
  /// **'Summarize'**
  String get summarize;

  /// No description provided for @sectionChats.
  ///
  /// In en, this message translates to:
  /// **'Chats'**
  String get sectionChats;

  /// No description provided for @sectionVoiceAi.
  ///
  /// In en, this message translates to:
  /// **'Voice & AI'**
  String get sectionVoiceAi;

  /// No description provided for @noChatsYet.
  ///
  /// In en, this message translates to:
  /// **'No chats yet'**
  String get noChatsYet;

  /// No description provided for @noChatsHint.
  ///
  /// In en, this message translates to:
  /// **'Tap the pencil to start a chat with anyone — phone, email, or @username.'**
  String get noChatsHint;

  /// No description provided for @rtlHint.
  ///
  /// In en, this message translates to:
  /// **'Urdu and Arabic use right-to-left layout.'**
  String get rtlHint;

  /// No description provided for @voiceDictate.
  ///
  /// In en, this message translates to:
  /// **'Dictate'**
  String get voiceDictate;

  /// No description provided for @voiceDictateHint.
  ///
  /// In en, this message translates to:
  /// **'Tap to speak — text fills the message box'**
  String get voiceDictateHint;

  /// No description provided for @voiceListening.
  ///
  /// In en, this message translates to:
  /// **'Listening…'**
  String get voiceListening;

  /// No description provided for @voiceReadAloud.
  ///
  /// In en, this message translates to:
  /// **'Read aloud'**
  String get voiceReadAloud;

  /// No description provided for @voiceStopSpeaking.
  ///
  /// In en, this message translates to:
  /// **'Stop speaking'**
  String get voiceStopSpeaking;

  /// No description provided for @checkForUpdates.
  ///
  /// In en, this message translates to:
  /// **'Check for updates'**
  String get checkForUpdates;

  /// No description provided for @upToDate.
  ///
  /// In en, this message translates to:
  /// **'You\'re on the latest build'**
  String get upToDate;

  /// No description provided for @autoUpdate.
  ///
  /// In en, this message translates to:
  /// **'Auto-update'**
  String get autoUpdate;

  /// No description provided for @autoUpdateSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Download new builds in-app automatically (default on)'**
  String get autoUpdateSubtitle;

  /// No description provided for @updateAvailable.
  ///
  /// In en, this message translates to:
  /// **'Update available'**
  String get updateAvailable;

  /// No description provided for @messageHint.
  ///
  /// In en, this message translates to:
  /// **'Message'**
  String get messageHint;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) => <String>[
        'ar',
        'en',
        'pa',
        'ru',
        'tr',
        'ur'
      ].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'ar':
      return AppLocalizationsAr();
    case 'en':
      return AppLocalizationsEn();
    case 'pa':
      return AppLocalizationsPa();
    case 'ru':
      return AppLocalizationsRu();
    case 'tr':
      return AppLocalizationsTr();
    case 'ur':
      return AppLocalizationsUr();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
