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
  late final Translations$core$en core = Translations$core$en.internal(_root);
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

  /// Button dismissing an informational notice.
  ///
  /// en: 'Got it'
  String get gotIt => 'Got it';

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

  /// Error shown when the maximum number of files is reached. {max} is the limit.
  ///
  /// en: 'You can add up to {max} files'
  String maxReached({required Object max}) => 'You can add up to ${max} files';

  /// Validation message when too few files are selected. {min} is the minimum.
  ///
  /// en: 'Add at least {min} file(s)'
  String validationIndicatingMinimum({required Object min}) => 'Add at least ${min} file(s)';

  /// Validation message when too many files are selected. {max} is the maximum.
  ///
  /// en: 'Add at most {max} files'
  String validationIndicatingMaximum({required Object max}) => 'Add at most ${max} files';
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
  /// en: 'Texa's AI Agent is powered by the Meta AI models. Provide your valid Meta AI API Kay to continue.'
  String get privacyNote =>
      'Texa\'s AI Agent is powered by the Meta AI models. Provide your valid Meta AI API Kay to continue.';

  /// Label for the API key field in setup and Settings.
  ///
  /// en: 'Meta AI API key'
  String get apiKeyLabel => 'Meta AI API key';

  /// Placeholder in the API key field.
  ///
  /// en: 'Paste your API key'
  String get apiKeyHint => 'Paste your API key';

  /// Note under the API key field explaining secure on-device storage.
  ///
  /// en: 'Your key is stored securely on this device and never leaves it except to call Meta AI.'
  String get apiKeySecureNote =>
      'Your key is stored securely on this device and never leaves it except to call Meta AI.';

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

  /// Model dropdown option that reveals a free-text model name field.
  ///
  /// en: 'Custom'
  String get customModel => 'Custom';

  /// Text field for typing a model name in the picker.
  ///
  /// en: 'Model name'
  String get modelNameLabel => 'Model name';

  /// Confirm button in the model picker.
  ///
  /// en: 'Create session'
  String get createSession => 'Create session';

  /// Label for the reasoning-effort dropdown in the new-session dialog.
  ///
  /// en: 'Reasoning effort'
  String get reasoningLabel => 'Reasoning effort';

  /// Reasoning effort: do not send a reasoning parameter.
  ///
  /// en: 'None (model default)'
  String get reasoningNone => 'None (model default)';

  /// Reasoning effort option: minimal.
  ///
  /// en: 'Minimal'
  String get reasoningMinimal => 'Minimal';

  /// Reasoning effort option: low.
  ///
  /// en: 'Low'
  String get reasoningLow => 'Low';

  /// Reasoning effort option: medium.
  ///
  /// en: 'Medium'
  String get reasoningMedium => 'Medium';

  /// Reasoning effort option: high.
  ///
  /// en: 'High'
  String get reasoningHigh => 'High';

  /// Reasoning effort option: xhigh.
  ///
  /// en: 'Extra high'
  String get reasoningXHigh => 'Extra high';

  /// Home session card chip showing the session reasoning effort.
  ///
  /// en: 'Reasoning: {effort}'
  String reasoningChip({required Object effort}) => 'Reasoning: ${effort}';
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

  /// Status pill while Texa is busy but not thinking, speaking or drawing a specific thing.
  ///
  /// en: 'Working…'
  String get working => 'Working…';

  /// Status pill while Texa writes text on the board.
  ///
  /// en: 'Writing text…'
  String get writingText => 'Writing text…';

  /// Status pill while Texa writes a math expression on the board.
  ///
  /// en: 'Writing math expression…'
  String get writingMath => 'Writing math expression…';

  /// Status pill while Texa plots a function on the board.
  ///
  /// en: 'Plotting function…'
  String get plottingFunction => 'Plotting function…';

  /// Status pill while Texa draws a diagram on the board.
  ///
  /// en: 'Drawing diagram…'
  String get drawingDiagram => 'Drawing diagram…';

  /// Status pill while Texa marks landmark points on the board.
  ///
  /// en: 'Marking landmarks…'
  String get markingLandmarks => 'Marking landmarks…';

  /// Status pill while Texa edits a board element.
  ///
  /// en: 'Editing element…'
  String get editingElement => 'Editing element…';

  /// Status pill while Texa removes a board element.
  ///
  /// en: 'Removing element…'
  String get removingElement => 'Removing element…';

  /// Status pill while Texa points at something on the board.
  ///
  /// en: 'Pointing…'
  String get pointing => 'Pointing…';

  /// Status pill while Texa moves the board view.
  ///
  /// en: 'Moving view…'
  String get movingView => 'Moving view…';

  /// Status pill while Texa quietly updates its notes or memory.
  ///
  /// en: 'Taking notes…'
  String get takingNotes => 'Taking notes…';

  /// Status pill while Texa searches past session observations.
  ///
  /// en: 'Searching past sessions…'
  String get searchingSessions => 'Searching past sessions…';

  /// History label for a write_text action.
  ///
  /// en: 'Wrote text'
  String get wroteText => 'Wrote text';

  /// History label for a write_math action.
  ///
  /// en: 'Wrote math expression'
  String get wroteMath => 'Wrote math expression';

  /// History label for a plot_function action.
  ///
  /// en: 'Plotted function'
  String get plottedFunction => 'Plotted function';

  /// History label for a draw_svg action.
  ///
  /// en: 'Drew diagram'
  String get drewDiagram => 'Drew diagram';

  /// History label for a mark_landmarks action.
  ///
  /// en: 'Marked landmarks'
  String get markedLandmarks => 'Marked landmarks';

  /// History label for an edit_element action.
  ///
  /// en: 'Edited element'
  String get editedElement => 'Edited element';

  /// History label for a remove_element action.
  ///
  /// en: 'Removed element'
  String get removedElement => 'Removed element';

  /// History label for a point_at action.
  ///
  /// en: 'Pointed at'
  String get pointedAt => 'Pointed at';

  /// History label for a focus_viewport action.
  ///
  /// en: 'Moved view'
  String get movedView => 'Moved view';

  /// Hint shown when microphone permission was denied.
  ///
  /// en: 'Draw-only mode — draw on the board or attach a file, or enable the microphone in Settings.'
  String get drawOnlyHint =>
      'Draw-only mode — draw on the board or attach a file, or enable the microphone in Settings.';

  /// Hint encouraging the student to speak while drawing.
  ///
  /// en: 'I'm listening — tell me what you're doing'
  String get listenHint => 'I\'m listening — tell me what you\'re doing';

  /// Button that stops AI speech and drawing.
  ///
  /// en: 'Stop'
  String get stop => 'Stop';

  /// Pen tool tooltip.
  ///
  /// en: 'Pen'
  String get pen => 'Pen';

  /// Tooltip for the straight-line drawing tool.
  ///
  /// en: 'Straight line'
  String get lineTool => 'Straight line';

  /// Tooltip for the pen colour picker button.
  ///
  /// en: 'Pen colour'
  String get penColor => 'Pen colour';

  /// Eraser tool tooltip.
  ///
  /// en: 'Eraser'
  String get eraser => 'Eraser';

  /// Toolbar slider tooltip: width of pen and straight-line strokes.
  ///
  /// en: 'Stroke width'
  String get strokeWidth => 'Stroke width';

  /// Toolbar slider tooltip: eraser size.
  ///
  /// en: 'Eraser width'
  String get eraserWidth => 'Eraser width';

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

  late final Translations$session$inputFile$en inputFile = Translations$session$inputFile$en.internal(_root);
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

  /// Section heading for the TTS voice engine settings.
  ///
  /// en: 'Tutor voice'
  String get voiceSection => 'Tutor voice';

  /// Name of the Kokoro TTS engine option.
  ///
  /// en: 'Kokoro'
  String get voiceKokoro => 'Kokoro';

  /// Description of the Kokoro TTS engine option.
  ///
  /// en: 'High quality, but may run slow on mobile and low-end devices.'
  String get voiceKokoroDescription => 'High quality, but may run slow on mobile and low-end devices.';

  /// Name of the Piper TTS engine option.
  ///
  /// en: 'Piper'
  String get voicePiper => 'Piper';

  /// Description of the Piper TTS engine option.
  ///
  /// en: 'Standard quality and uses fewer resources. Recommended for mobile.'
  String get voicePiperDescription => 'Standard quality and uses fewer resources. Recommended for mobile.';

  /// Badge marking the voice engine recommended for this device.
  ///
  /// en: 'Recommended'
  String get voiceRecommended => 'Recommended';

  /// Error shown when downloading or switching the voice engine fails.
  ///
  /// en: 'Could not download/switch the voice. Please try again.'
  String get voiceDownloadFailed => 'Could not download/switch the voice. Please try again.';

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

  /// Section heading for the tutor's long-term memory of the student.
  ///
  /// en: 'Tutor memory'
  String get memorySection => 'Tutor memory';

  /// Explains what the long-term memory is and that the user can edit it.
  ///
  /// en: 'What Texa remembers about the student across all sessions: level, goals, preferences and learning patterns. Texa updates this itself; you can also edit it here.'
  String get memoryDescription =>
      'What Texa remembers about the student across all sessions: level, goals, preferences and learning patterns. Texa updates this itself; you can also edit it here.';

  /// Label for the editable long-term memory text field.
  ///
  /// en: 'Memory'
  String get memoryLabel => 'Memory';

  /// Placeholder for an empty long-term memory.
  ///
  /// en: 'Nothing remembered yet.'
  String get memoryHint => 'Nothing remembered yet.';
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

// Path: core
class Translations$core$en {
  Translations$core$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations
  late final Translations$core$files$en files = Translations$core$files$en.internal(_root);
}

// Path: session.inputFile
class Translations$session$inputFile$en {
  Translations$session$inputFile$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// Button that opens the file upload modal.
  ///
  /// en: 'Add files'
  String get addFiles => 'Add files';

  /// Title of the file upload modal.
  ///
  /// en: 'Add files'
  String get uploadTitle => 'Add files';

  /// Upload option: pick images from the gallery.
  ///
  /// en: 'Photo gallery'
  String get imageGallery => 'Photo gallery';

  /// Upload option: take a photo with the camera.
  ///
  /// en: 'Camera'
  String get camera => 'Camera';

  /// Upload option: pick files from storage.
  ///
  /// en: 'Browse files'
  String get selectFiles => 'Browse files';

  /// Upload option: record audio in the app.
  ///
  /// en: 'Record audio'
  String get recordAudio => 'Record audio';

  /// Tooltip for the record audio button.
  ///
  /// en: 'Record audio'
  String get recordAudioTooltip => 'Record audio';

  /// Error when a file exceeds the size limit. {sizeInMb} is the limit in megabytes.
  ///
  /// en: 'Files must be {sizeInMb} MB or smaller'
  String fileTooLarge({required Object sizeInMb}) => 'Files must be ${sizeInMb} MB or smaller';

  /// Empty state in the upload modal grid.
  ///
  /// en: 'No files selected yet. Choose an option above to add some.'
  String get noFilesYet => 'No files selected yet. Choose an option above to add some.';

  /// Label on the file control showing how many files are attached. {count} is the number.
  ///
  /// en: '{count} file(s) attached'
  String filesAttached({required Object count}) => '${count} file(s) attached';

  /// Tooltip for removing a selected file.
  ///
  /// en: 'Remove file'
  String get removeFile => 'Remove file';
}

// Path: core.files
class Translations$core$files$en {
  Translations$core$files$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// Shown when an audio recording reaches its maximum length.
  ///
  /// en: 'Maximum recording length reached'
  String get recordingMaxDuration => 'Maximum recording length reached';
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
      'common.gotIt' => 'Got it',
      'common.cancel' => 'Cancel',
      'common.delete' => 'Delete',
      'common.rename' => 'Rename',
      'common.save' => 'Save',
      'common.retry' => 'Retry',
      'common.kContinue' => 'Continue',
      'common.back' => 'Back',
      'common.close' => 'Close',
      'common.maxReached' => ({required Object max}) => 'You can add up to ${max} files',
      'common.validationIndicatingMinimum' => ({required Object min}) => 'Add at least ${min} file(s)',
      'common.validationIndicatingMaximum' => ({required Object max}) => 'Add at most ${max} files',
      'setup.welcomeTitle' => 'Your AI tutor that draws with you',
      'setup.welcomeBody' => 'Draw on the shared board, talk out loud, and Texa will explain step by step — writing, drawing and pointing right on your work.',
      'setup.privacyNote' =>
        'Texa\'s AI Agent is powered by the Meta AI models. Provide your valid Meta AI API Kay to continue.',
      'setup.apiKeyLabel' => 'Meta AI API key',
      'setup.apiKeyHint' => 'Paste your API key',
      'setup.apiKeySecureNote' =>
        'Your key is stored securely on this device and never leaves it except to call Meta AI.',
      'setup.testConnection' => 'Test connection',
      'setup.testing' => 'Testing…',
      'setup.connectionOk' => 'Connection works — you are ready.',
      'setup.connectionFailed' => 'That key did not work. Check it and try again.',
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
      'home.customModel' => 'Custom',
      'home.modelNameLabel' => 'Model name',
      'home.createSession' => 'Create session',
      'home.reasoningLabel' => 'Reasoning effort',
      'home.reasoningNone' => 'None (model default)',
      'home.reasoningMinimal' => 'Minimal',
      'home.reasoningLow' => 'Low',
      'home.reasoningMedium' => 'Medium',
      'home.reasoningHigh' => 'High',
      'home.reasoningXHigh' => 'Extra high',
      'home.reasoningChip' => ({required Object effort}) => 'Reasoning: ${effort}',
      'session.listening' => 'Listening…',
      'session.capturing' => 'Listening — I can hear you',
      'session.thinking' => 'Thinking…',
      'session.speaking' => 'Speaking…',
      'session.muted' => 'Microphone off',
      'session.working' => 'Working…',
      'session.writingText' => 'Writing text…',
      'session.writingMath' => 'Writing math expression…',
      'session.plottingFunction' => 'Plotting function…',
      'session.drawingDiagram' => 'Drawing diagram…',
      'session.markingLandmarks' => 'Marking landmarks…',
      'session.editingElement' => 'Editing element…',
      'session.removingElement' => 'Removing element…',
      'session.pointing' => 'Pointing…',
      'session.movingView' => 'Moving view…',
      'session.takingNotes' => 'Taking notes…',
      'session.searchingSessions' => 'Searching past sessions…',
      'session.wroteText' => 'Wrote text',
      'session.wroteMath' => 'Wrote math expression',
      'session.plottedFunction' => 'Plotted function',
      'session.drewDiagram' => 'Drew diagram',
      'session.markedLandmarks' => 'Marked landmarks',
      'session.editedElement' => 'Edited element',
      'session.removedElement' => 'Removed element',
      'session.pointedAt' => 'Pointed at',
      'session.movedView' => 'Moved view',
      'session.drawOnlyHint' =>
        'Draw-only mode — draw on the board or attach a file, or enable the microphone in Settings.',
      'session.listenHint' => 'I\'m listening — tell me what you\'re doing',
      'session.stop' => 'Stop',
      'session.pen' => 'Pen',
      'session.lineTool' => 'Straight line',
      'session.penColor' => 'Pen colour',
      'session.eraser' => 'Eraser',
      'session.strokeWidth' => 'Stroke width',
      'session.eraserWidth' => 'Eraser width',
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
      'session.retryTurn' => 'Retry turn',
      'session.history' => 'History',
      'session.noHistory' => 'Nothing here yet. Draw and ask your first question.',
      'session.inputFile.addFiles' => 'Add files',
      'session.inputFile.uploadTitle' => 'Add files',
      'session.inputFile.imageGallery' => 'Photo gallery',
      'session.inputFile.camera' => 'Camera',
      'session.inputFile.selectFiles' => 'Browse files',
      'session.inputFile.recordAudio' => 'Record audio',
      'session.inputFile.recordAudioTooltip' => 'Record audio',
      'session.inputFile.fileTooLarge' => ({required Object sizeInMb}) => 'Files must be ${sizeInMb} MB or smaller',
      'session.inputFile.noFilesYet' => 'No files selected yet. Choose an option above to add some.',
      'session.inputFile.filesAttached' => ({required Object count}) => '${count} file(s) attached',
      'session.inputFile.removeFile' => 'Remove file',
      'settings.title' => 'Settings',
      'settings.apiSection' => 'Meta AI connection',
      'settings.captionsDefault' => 'Captions on by default',
      'settings.playbackSection' => 'Playback',
      'settings.voiceSection' => 'Tutor voice',
      'settings.voiceKokoro' => 'Kokoro',
      'settings.voiceKokoroDescription' => 'High quality, but may run slow on mobile and low-end devices.',
      'settings.voicePiper' => 'Piper',
      'settings.voicePiperDescription' => 'Standard quality and uses fewer resources. Recommended for mobile.',
      'settings.voiceRecommended' => 'Recommended',
      'settings.voiceDownloadFailed' => 'Could not download/switch the voice. Please try again.',
      'settings.dataSection' => 'Your data',
      'settings.deleteAll' => 'Delete all sessions and remove API key',
      'settings.deleteAllTitle' => 'Delete everything?',
      'settings.deleteAllBody' => 'All sessions, boards and your API key will be removed from this device.',
      'settings.logs' => 'Debug logs',
      'settings.saved' => 'Saved',
      'settings.memorySection' => 'Tutor memory',
      'settings.memoryDescription' => 'What Texa remembers about the student across all sessions: level, goals, preferences and learning patterns. Texa updates this itself; you can also edit it here.',
      'settings.memoryLabel' => 'Memory',
      'settings.memoryHint' => 'Nothing remembered yet.',
      'errors.network' => 'Could not reach Meta AI. Check your connection and try again.',
      'errors.turnFailed' => 'That turn could not be sent. Your work is safe on the board.',
      'core.files.recordingMaxDuration' => 'Maximum recording length reached',
      _ => null,
    };
  }
}
