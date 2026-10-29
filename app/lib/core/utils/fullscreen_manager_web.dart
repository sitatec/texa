import 'dart:js_interop';

import 'package:web/web.dart';

import 'fullscreen_manager_types.dart';

/// Web fullscreen via the document Fullscreen API.
class FullScreenManagerImpl {
  void _onFullScreenChange(Event event) {
    // Replaced by the real listener in listenToFullScreenChange.
  }

  // Store the JS-converted function so it has a stable reference.
  late JSFunction _fullScreenChangeListener = _onFullScreenChange.toJS;

  void enterFullScreen() {
    document.documentElement?.requestFullscreen();
  }

  void exitFullScreen() {
    document.exitFullscreen();
  }

  void listenToFullScreenChange(void Function(SystemUIChangeType) onChange) {
    _fullScreenChangeListener = ((event) {
      if (document.fullscreenElement == null) {
        onChange(SystemUIChangeType.exitFullScreen);
      } else {
        onChange(SystemUIChangeType.enterFullScreen);
      }
    } as void Function(Event)).toJS;
    document.addEventListener('fullscreenchange', _fullScreenChangeListener);
  }

  void dispose() {
    document.removeEventListener('fullscreenchange', _fullScreenChangeListener);
  }
}

FullScreenManagerImpl createFullScreenManager() => FullScreenManagerImpl();
