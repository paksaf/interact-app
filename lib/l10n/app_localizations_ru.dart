// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Russian (`ru`).
class AppLocalizationsRu extends AppLocalizations {
  AppLocalizationsRu([String locale = 'ru']) : super(locale);

  @override
  String get appTitle => 'INTERACT';

  @override
  String get tabCalls => 'Звонки';

  @override
  String get tabChats => 'Чаты';

  @override
  String get tabContacts => 'Контакты';

  @override
  String get tabMe => 'Я';

  @override
  String get languages => 'Языки';

  @override
  String get languagesSubtitle => 'EN · UR · AR · TR · RU · PA';

  @override
  String get languageSystem => 'Как в системе';

  @override
  String get languageEnglish => 'Английский';

  @override
  String get languageUrdu => 'Урду';

  @override
  String get languageArabic => 'Арабский';

  @override
  String get languageTurkish => 'Турецкий';

  @override
  String get languageRussian => 'Русский';

  @override
  String get languagePunjabi => 'Панджаби';

  @override
  String get chooseLanguage => 'Выберите язык';

  @override
  String get cancel => 'Отмена';

  @override
  String get save => 'Сохранить';

  @override
  String get done => 'Готово';

  @override
  String get signInTitle => 'Вход';

  @override
  String get signInSubtitle =>
      'Телефон или email INTERACT — один вход во всех приложениях.';

  @override
  String get phoneOrEmail => 'Телефон или email';

  @override
  String get sendCode => 'Отправить код';

  @override
  String get verifyCode => 'Подтвердить';

  @override
  String get otpHint => '6-значный код';

  @override
  String get privateAiComingSoon => 'Приватный AI (скоро)';

  @override
  String get privateAiOffSubtitle =>
      'Выкл. — чат в облаке. Локальная модель ещё не готова.';

  @override
  String get privateAiOnSubtitle => 'Вкл. — заблокировано до модели (фаза 3).';

  @override
  String get voiceNoteTranscription => 'Транскрипт голосовых';

  @override
  String get voiceNoteTranscriptionSubtitle =>
      'Облачный Whisper при OPENAI_API_KEY на Talk API';

  @override
  String get onDeviceCapability => 'Возможности на устройстве';

  @override
  String get backupRestore => 'Резервная копия';

  @override
  String get backupSubtitle => 'Шифрованный архив чатов';

  @override
  String get communities => 'Сообщества';

  @override
  String get communitiesSubtitle => 'Ваши группы';

  @override
  String get setUsername => 'Задать @username';

  @override
  String get profilePhoto => 'Фото профиля';

  @override
  String get newChat => 'Новый чат';

  @override
  String get newChatSubtitle => 'По телефону, email или @username';

  @override
  String get newGroup => 'Новая группа';

  @override
  String get newChannel => 'Новый канал';

  @override
  String get newCommunity => 'Новое сообщество';

  @override
  String get captions => 'Субтитры';

  @override
  String get captionsUnavailable => 'Субтитры сейчас недоступны.';

  @override
  String get mute => 'Без звука';

  @override
  String get unmute => 'Включить звук';

  @override
  String get cameraOn => 'Камера вкл.';

  @override
  String get cameraOff => 'Камера выкл.';

  @override
  String get shareScreen => 'Демонстрация';

  @override
  String get stopShare => 'Стоп демо';

  @override
  String get leave => 'Выйти';

  @override
  String get endCall => 'Завершить';

  @override
  String get meetingSummary => 'Итог встречи';

  @override
  String get summaryLanguage => 'Язык итога';

  @override
  String get summarize => 'Суммировать';

  @override
  String get sectionChats => 'Чаты';

  @override
  String get sectionVoiceAi => 'Голос и AI';

  @override
  String get noChatsYet => 'Чатов пока нет';

  @override
  String get noChatsHint => 'Нажмите карандаш — телефон, email или @username.';

  @override
  String get rtlHint => 'Урду и арабский используют справа-налево.';

  @override
  String get voiceDictate => 'Диктовка';

  @override
  String get voiceDictateHint =>
      'Нажмите, чтобы говорить — текст попадёт в поле сообщения';

  @override
  String get voiceListening => 'Слушаю…';

  @override
  String get voiceReadAloud => 'Прочитать вслух';

  @override
  String get voiceStopSpeaking => 'Остановить';

  @override
  String get checkForUpdates => 'Проверить обновления';

  @override
  String get upToDate => 'У вас последняя версия';

  @override
  String get autoUpdate => 'Автообновление';

  @override
  String get autoUpdateSubtitle =>
      'Скачивать новые сборки в приложении автоматически (по умолчанию вкл.)';

  @override
  String get updateAvailable => 'Доступно обновление';

  @override
  String get messageHint => 'Сообщение';

  @override
  String get themeSettings => 'Тема и цвета';

  @override
  String get themeSettingsSubtitle => 'Светлая, тёмная, пресеты';

  @override
  String get themeMode => 'Режим';

  @override
  String get themeModeSystem => 'Система';

  @override
  String get themeModeLight => 'Светлая';

  @override
  String get themeModeDark => 'Тёмная';

  @override
  String get themePresets => 'Выберите тему';

  @override
  String get themePresetSignal => 'Signal';

  @override
  String get themePresetSaffron => 'Saffron';

  @override
  String get themePresetIndigo => 'Indigo Night';

  @override
  String get themePresetForest => 'Forest';

  @override
  String get themePresetPlum => 'Plum';

  @override
  String get themePresetGraphite => 'Graphite';

  @override
  String get themeCustom => 'Своя';

  @override
  String get themeCustomHint =>
      'Настройте оттенок — яркость в читаемом диапазоне.';

  @override
  String get themeHue => 'Hue';

  @override
  String get themeSaturation => 'Saturation';

  @override
  String get themeLightness => 'Lightness';

  @override
  String get themePickAccent => 'Отдельный accent';

  @override
  String get themeAccentHue => 'Accent hue';

  @override
  String get themeApplyCustom => 'Применить';

  @override
  String get themePreview => 'Просмотр';

  @override
  String get themePreviewAiCta => 'Спросить INTERACT AI';

  @override
  String get themeReset => 'Сброс Signal + System';
}
