import 'fullscreen_manager_stub.dart'
    if (dart.library.io) 'fullscreen_manager_io.dart'
    if (dart.library.js_interop) 'fullscreen_manager_web.dart'
    as impl;

export 'fullscreen_manager_types.dart';

import 'fullscreen_manager_types.dart';

/// Fullscreen control on every platform. The web implementation talks
/// to the document Fullscreen API; native platforms use SystemChrome.
/// Split by conditional import because `package:web` cannot compile
/// off-web (a runtime `kIsWeb` check around a web import is not
/// enough — the import itself breaks VM builds and tests).
class FullScreenManager {
  final impl.FullScreenManagerImpl _impl = impl.createFullScreenManager();

  void enterFullScreen() => _impl.enterFullScreen();
  void exitFullScreen() => _impl.exitFullScreen();
  void listenToFullScreenChange(void Function(SystemUIChangeType) onChange) =>
      _impl.listenToFullScreenChange(onChange);
  void dispose() => _impl.dispose();
}
