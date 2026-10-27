///
/// Generated file. Do not edit.
///
// coverage:ignore-file
// ignore_for_file: type=lint, unused_import

part of 'translations.g.dart';

// Path: <root>
typedef TranslationsEn = Translations; // ignore: unused_element

class Translations with BaseTranslations<AppLocale, Translations> {
  /// Returns the current translations of the given [context].
  ///
  /// Usage:
  /// final tr = Translations.of(context);
  static Translations of(BuildContext context) => InheritedLocaleData.of<AppLocale, Translations>(context).translations;

  /// You can call this constructor and build your own translation instance of this locale.
  /// Constructing via the enum [AppLocale.build] is preferred.
  Translations({
    Map<String, Node>? overrides,
    PluralResolver? cardinalResolver,
    PluralResolver? ordinalResolver,
    TranslationMetadata<AppLocale, Translations>? meta,
  }) : assert(overrides == null, 'Set "translation_overrides: true" in order to enable this feature.'),
       _meta =
           meta ??
           TranslationMetadata(
             locale: AppLocale.en,
             overrides: overrides ?? {},
             cardinalResolver: cardinalResolver,
             ordinalResolver: ordinalResolver,
           ) {
    _meta.setFlatMapFunction(_flatMapFunction);
  }

  /// Metadata for the translations of <en>.
  final TranslationMetadata<AppLocale, Translations> _meta;
  @override
  TranslationMetadata<AppLocale, Translations> get $meta => _meta;

  /// Access flat map
  dynamic operator [](String key) => _meta.getTranslation(key);

  late final Translations _root = this; // ignore: unused_field

  Translations $copyWith({TranslationMetadata<AppLocale, Translations>? meta}) =>
      Translations(meta: meta ?? this.$meta);

  // Translations
  late final Translations$app$en app = Translations$app$en.internal(_root);
  late final Translations$common$en common = Translations$common$en.internal(_root);
  late final Translations$setup$en setup = Translations$setup$en.internal(_root);
  late final Translations$home$en home = Translations$home$en.internal(_root);
  late final Translations$session$en session = Translations$session$en.internal(_root);
  late final Translations$settings$en settings = Translations$settings$en.internal(_root);
  late final Translations$errors$en errors = Translations$errors$en.internal(_root);
}

// Path: app
class Translations$app$en {
  Translations$app$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// App title shown in the app bar and system UI.
  ///
  /// en: 'Texa'
  String get title => 'Texa';
}

// Path: common
class Translations$common$en {
  Translations$common$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// Cancel button in dialogs.
  ///
  /// en: 'Cancel'
  String get cancel => 'Cancel';

  /// Delete button in dialogs and menus.
  ///
  /// en: 'Delete'
  String get delete => 'Delete';

  /// Rename action in a session overflow menu.
  ///
  /// en: 'Rename'
  String get rename => 'Rename';

  /// Save button in dialogs.
  ///
  /// en: 'Save'
  String get save => 'Save';

  /// Retry button after a failure.
  ///
  /// en: 'Retry'
  String get retry => 'Retry';

  /// en: 'Continue'
  String get kContinue => 'Continue';

  /// Back button tooltip.
  ///
  /// en: 'Back'
  String get back => 'Back';

  /// Close button tooltip.
  ///
  /// en: 'Close'
  String get close => 'Close';
}

// Path: setup
class Translations$setup$en {
  Translations$setup$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// Headline on the first-launch welcome screen.
  ///
  /// en: 'Your AI tutor that draws with you'
  String get welcomeTitle => 'Your AI tutor that draws with you';

  /// Explanation on the welcome screen.
  ///
  /// en: 'Draw on the shared board, talk out loud, and Texa will explain step by step — writing, drawing and pointing right on your work.'
  String get welcomeBody =>
      'Draw on the shared board, talk out loud, and Texa will explain step by step — writing, drawing and pointing right on your work.';

  /// Privacy note in setup and Settings.
  ///
  /// en: 'Your board and voice are sent to Meta AI so the tutor can see and hear your work. Nothing is sent to Texa servers — there are none.'
  String get privacyNote =>
      'Your board and voice are sent to Meta AI so the tutor can see and hear your work. Nothing is sent to Texa servers — there are none.';

  /// Label for the API key field in setup and Settings.
  ///
  /// en: 'Meta AI API key'
  String get apiKeyLabel => 'Meta AI API key';

  /// Placeholder in the API key field.
  ///
  /// en: 'Paste your API key'
  String get apiKeyHint => 'Paste your API key';

  /// Button that checks the API key works.
  ///
  /// en: 'Test connection'
  String get testConnection => 'Test connection';

  /// Shown while the connection test runs.
  ///
  /// en: 'Testing…'
  String get testing => 'Testing…';

  /// Success message after testing the API key.
  ///
  /// en: 'Connection works — you are ready.'
  String get connectionOk => 'Connection works — you are ready.';

  /// Error after a failed connection test.
  ///
  /// en: 'That key did not work. Check it and try again.'
  String get connectionFailed => 'That key did not work. Check it and try again.';

  /// Heading for the microphone permission step.
  ///
  /// en: 'Talk while you draw'
  String get micTitle => 'Talk while you draw';

  /// Explanation for microphone permission.
  ///
  /// en: 'Texa listens so you can explain your thinking out loud. You can use Texa without the microphone, drawing and typing instead.'
  String get micBody =>
      'Texa listens so you can explain your thinking out loud. You can use Texa without the microphone, drawing and typing instead.';

  /// Button requesting microphone permission.
  ///
  /// en: 'Allow microphone'
  String get allowMic => 'Allow microphone';

  /// Button to continue without microphone permission.
  ///
  /// en: 'Continue without microphone'
  String get skipMic => 'Continue without microphone';

  /// Heading while on-device speech models download.
  ///
  /// en: 'Setting up speech'
  String get modelsTitle => 'Setting up speech';

  /// Explanation on the model download screen.
  ///
  /// en: 'Texa downloads its on-device voice models once. This can take a few minutes on a slow connection.'
  String get modelsBody =>
      'Texa downloads its on-device voice models once. This can take a few minutes on a slow connection.';

  /// Shown when speech models are installed and verified.
  ///
  /// en: 'Speech is ready'
  String get modelsReady => 'Speech is ready';

  /// Error on the model download screen.
  ///
  /// en: 'Speech models could not be set up.'
  String get modelsFailed => 'Speech models could not be set up.';

  /// Download progress. {name} is the model name, {percent} is 0-100.
  ///
  /// en: 'Downloading {name}… {percent}%'
  String downloading({required Object name, required Object percent}) => 'Downloading ${name}… ${percent}%';
}

// Path: home
class Translations$home$en {
  Translations$home$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// Home screen title.
  ///
  /// en: 'Texa'
  String get title => 'Texa';

  /// Primary button on Home. Opens the model picker and creates a session.
  ///
  /// en: 'New session'
  String get newSession => 'New session';

  /// Empty-state heading when there are no sessions.
  ///
  /// en: 'Start learning with Texa'
  String get emptyTitle => 'Start learning with Texa';

  /// Empty-state explanation on Home.
  ///
  /// en: 'Create a session, draw your problem on the board, and talk Texa through it.'
  String get emptyBody => 'Create a session, draw your problem on the board, and talk Texa through it.';

  /// Settings button tooltip on Home.
  ///
  /// en: 'Settings'
  String get settings => 'Settings';

  /// Confirmation dialog title for deleting a session.
  ///
  /// en: 'Delete this session?'
  String get deleteSessionTitle => 'Delete this session?';

  /// Confirmation dialog body for deleting a session.
  ///
  /// en: 'Its board and history will be permanently deleted from this device.'
  String get deleteSessionBody => 'Its board and history will be permanently deleted from this device.';

  /// Rename dialog title.
  ///
  /// en: 'Rename session'
  String get renameTitle => 'Rename session';

  /// Text field label in the rename dialog.
  ///
  /// en: 'Session name'
  String get sessionName => 'Session name';

  /// Heading in the model picker shown when creating a session.
  ///
  /// en: 'Choose the AI model'
  String get chooseModel => 'Choose the AI model';

  /// Explanation in the model picker.
  ///
  /// en: 'This model will tutor this session. It cannot be changed later.'
  String get chooseModelBody => 'This model will tutor this session. It cannot be changed later.';

  /// Text field for typing a model name in the picker.
  ///
  /// en: 'Model name'
  String get modelNameLabel => 'Model name';

  /// Button that fetches the model list from the API.
  ///
  /// en: 'Load available models'
  String get loadModels => 'Load available models';

  /// Confirm button in the model picker.
  ///
  /// en: 'Create session'
  String get createSession => 'Create session';
}

// Path: session
class Translations$session$en {
  Translations$session$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// Status pill when Texa is listening.
  ///
  /// en: 'Listening…'
  String get listening => 'Listening…';

  /// Status pill while the student is speaking.
  ///
  /// en: 'Listening — I can hear you'
  String get capturing => 'Listening — I can hear you';

  /// Status pill while waiting for the AI reply.
  ///
  /// en: 'Thinking…'
  String get thinking => 'Thinking…';

  /// Status pill while Texa speaks and draws.
  ///
  /// en: 'Speaking…'
  String get speaking => 'Speaking…';

  /// Status pill when the microphone is muted.
  ///
  /// en: 'Microphone off'
  String get muted => 'Microphone off';

  /// Hint shown when microphone permission was denied.
  ///
  /// en: 'Draw-only mode — type your question below, or enable the microphone in Settings.'
  String get drawOnlyHint => 'Draw-only mode — type your question below, or enable the microphone in Settings.';

  /// Hint encouraging the student to speak while drawing.
  ///
  /// en: 'I'm listening — tell me what you're doing'
  String get listenHint => 'I\'m listening — tell me what you\'re doing';

  /// Button that sends the current board and typed question to the tutor.
  ///
  /// en: 'Ask Texa'
  String get askTexa => 'Ask Texa';

  /// Placeholder for the typed question field.
  ///
  /// en: 'Type your question (optional)…'
  String get typeQuestion => 'Type your question (optional)…';

  /// Button that stops AI speech and drawing.
  ///
  /// en: 'Stop'
  String get stop => 'Stop';

  /// Pen tool tooltip.
  ///
  /// en: 'Pen'
  String get pen => 'Pen';

  /// Eraser tool tooltip.
  ///
  /// en: 'Eraser'
  String get eraser => 'Eraser';

  /// Undo tooltip.
  ///
  /// en: 'Undo'
  String get undo => 'Undo';

  /// Redo tooltip.
  ///
  /// en: 'Redo'
  String get redo => 'Redo';

  /// Clear board tooltip.
  ///
  /// en: 'Clear board'
  String get clearBoard => 'Clear board';

  /// Confirmation title before clearing the board.
  ///
  /// en: 'Clear the board?'
  String get clearTitle => 'Clear the board?';

  /// Confirmation body before clearing the board.
  ///
  /// en: 'Everything on the board will be erased. This cannot be undone.'
  String get clearBody => 'Everything on the board will be erased. This cannot be undone.';

  /// Tooltip to mute the microphone.
  ///
  /// en: 'Mute microphone'
  String get micOn => 'Mute microphone';

  /// Tooltip to unmute the microphone.
  ///
  /// en: 'Unmute microphone'
  String get micOff => 'Unmute microphone';

  /// Tooltip to hide captions.
  ///
  /// en: 'Turn captions off'
  String get captionsOn => 'Turn captions off';

  /// Tooltip to show captions.
  ///
  /// en: 'Turn captions on'
  String get captionsOff => 'Turn captions on';

  /// Fullscreen toggle tooltip.
  ///
  /// en: 'Fullscreen'
  String get fullscreen => 'Fullscreen';

  /// More button tooltip on compact layouts.
  ///
  /// en: 'More options'
  String get more => 'More options';

  /// Label for the optional subject selector.
  ///
  /// en: 'Subject'
  String get subject => 'Subject';

  /// Button that re-sends the last turn after a failure.
  ///
  /// en: 'Retry turn'
  String get retryTurn => 'Retry turn';

  /// Button opening the conversation history sheet.
  ///
  /// en: 'History'
  String get history => 'History';

  /// Empty text in the history sheet.
  ///
  /// en: 'Nothing here yet. Draw and ask your first question.'
  String get noHistory => 'Nothing here yet. Draw and ask your first question.';
}

// Path: settings
class Translations$settings$en {
  Translations$settings$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// Settings screen title.
  ///
  /// en: 'Settings'
  String get title => 'Settings';

  /// Section heading for API settings.
  ///
  /// en: 'Meta AI connection'
  String get apiSection => 'Meta AI connection';

  /// Switch for the default captions setting.
  ///
  /// en: 'Captions on by default'
  String get captionsDefault => 'Captions on by default';

  /// Section heading for playback settings.
  ///
  /// en: 'Playback'
  String get playbackSection => 'Playback';

  /// Section heading for data settings.
  ///
  /// en: 'Your data'
  String get dataSection => 'Your data';

  /// Danger button that wipes all local data.
  ///
  /// en: 'Delete all sessions and remove API key'
  String get deleteAll => 'Delete all sessions and remove API key';

  /// Confirmation title for wiping all data.
  ///
  /// en: 'Delete everything?'
  String get deleteAllTitle => 'Delete everything?';

  /// Confirmation body for wiping all data.
  ///
  /// en: 'All sessions, boards and your API key will be removed from this device.'
  String get deleteAllBody => 'All sessions, boards and your API key will be removed from this device.';

  /// Section heading for local debug logs.
  ///
  /// en: 'Debug logs'
  String get logs => 'Debug logs';

  /// Confirmation shown after saving settings.
  ///
  /// en: 'Saved'
  String get saved => 'Saved';
}

// Path: errors
class Translations$errors$en {
  Translations$errors$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// Plain-language network error.
  ///
  /// en: 'Could not reach Meta AI. Check your connection and try again.'
  String get network => 'Could not reach Meta AI. Check your connection and try again.';

  /// Error banner after a failed turn.
  ///
  /// en: 'That turn could not be sent. Your work is safe on the board.'
  String get turnFailed => 'That turn could not be sent. Your work is safe on the board.';
}

/// The flat map containing all translations for locale <en>.
/// Only for edge cases! For simple maps, use the map function of this library.
///
/// The Dart AOT compiler has issues with very large switch statements,
/// so the map is split into smaller functions (512 entries each).
extension on Translations {
  dynamic _flatMapFunction(String path) {
    return switch (path) {
      'app.title' => 'Texa',
      'common.cancel' => 'Cancel',
      'common.delete' => 'Delete',
      'common.rename' => 'Rename',
      'common.save' => 'Save',
      'common.retry' => 'Retry',
      'common.kContinue' => 'Continue',
      'common.back' => 'Back',
      'common.close' => 'Close',
      'setup.welcomeTitle' => 'Your AI tutor that draws with you',
      'setup.welcomeBody' => 'Draw on the shared board, talk out loud, and Texa will explain step by step — writing, drawing and pointing right on your work.',
      'setup.privacyNote' => 'Your board and voice are sent to Meta AI so the tutor can see and hear your work. Nothing is sent to Texa servers — there are none.',
      'setup.apiKeyLabel' => 'Meta AI API key',
      'setup.apiKeyHint' => 'Paste your API key',
      'setup.testConnection' => 'Test connection',
      'setup.testing' => 'Testing…',
      'setup.connectionOk' => 'Connection works — you are ready.',
      'setup.connectionFailed' => 'That key did not work. Check it and try again.',
      'setup.micTitle' => 'Talk while you draw',
      'setup.micBody' => 'Texa listens so you can explain your thinking out loud. You can use Texa without the microphone, drawing and typing instead.',
      'setup.allowMic' => 'Allow microphone',
      'setup.skipMic' => 'Continue without microphone',
      'setup.modelsTitle' => 'Setting up speech',
      'setup.modelsBody' =>
        'Texa downloads its on-device voice models once. This can take a few minutes on a slow connection.',
      'setup.modelsReady' => 'Speech is ready',
      'setup.modelsFailed' => 'Speech models could not be set up.',
      'setup.downloading' => ({required Object name, required Object percent}) => 'Downloading ${name}… ${percent}%',
      'home.title' => 'Texa',
      'home.newSession' => 'New session',
      'home.emptyTitle' => 'Start learning with Texa',
      'home.emptyBody' => 'Create a session, draw your problem on the board, and talk Texa through it.',
      'home.settings' => 'Settings',
      'home.deleteSessionTitle' => 'Delete this session?',
      'home.deleteSessionBody' => 'Its board and history will be permanently deleted from this device.',
      'home.renameTitle' => 'Rename session',
      'home.sessionName' => 'Session name',
      'home.chooseModel' => 'Choose the AI model',
      'home.chooseModelBody' => 'This model will tutor this session. It cannot be changed later.',
      'home.modelNameLabel' => 'Model name',
      'home.loadModels' => 'Load available models',
      'home.createSession' => 'Create session',
      'session.listening' => 'Listening…',
      'session.capturing' => 'Listening — I can hear you',
      'session.thinking' => 'Thinking…',
      'session.speaking' => 'Speaking…',
      'session.muted' => 'Microphone off',
      'session.drawOnlyHint' => 'Draw-only mode — type your question below, or enable the microphone in Settings.',
      'session.listenHint' => 'I\'m listening — tell me what you\'re doing',
      'session.askTexa' => 'Ask Texa',
      'session.typeQuestion' => 'Type your question (optional)…',
      'session.stop' => 'Stop',
      'session.pen' => 'Pen',
      'session.eraser' => 'Eraser',
      'session.undo' => 'Undo',
      'session.redo' => 'Redo',
      'session.clearBoard' => 'Clear board',
      'session.clearTitle' => 'Clear the board?',
      'session.clearBody' => 'Everything on the board will be erased. This cannot be undone.',
      'session.micOn' => 'Mute microphone',
      'session.micOff' => 'Unmute microphone',
      'session.captionsOn' => 'Turn captions off',
      'session.captionsOff' => 'Turn captions on',
      'session.fullscreen' => 'Fullscreen',
      'session.more' => 'More options',
      'session.subject' => 'Subject',
      'session.retryTurn' => 'Retry turn',
      'session.history' => 'History',
      'session.noHistory' => 'Nothing here yet. Draw and ask your first question.',
      'settings.title' => 'Settings',
      'settings.apiSection' => 'Meta AI connection',
      'settings.captionsDefault' => 'Captions on by default',
      'settings.playbackSection' => 'Playback',
      'settings.dataSection' => 'Your data',
      'settings.deleteAll' => 'Delete all sessions and remove API key',
      'settings.deleteAllTitle' => 'Delete everything?',
      'settings.deleteAllBody' => 'All sessions, boards and your API key will be removed from this device.',
      'settings.logs' => 'Debug logs',
      'settings.saved' => 'Saved',
      'errors.network' => 'Could not reach Meta AI. Check your connection and try again.',
      'errors.turnFailed' => 'That turn could not be sent. Your work is safe on the board.',
      _ => null,
    };
  }
}
