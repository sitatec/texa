import 'package:flutter/services.dart';

import 'fullscreen_manager_types.dart';

/// Native fullscreen via SystemChrome immersive mode.
class FullScreenManagerImpl {
  void enterFullScreen() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
  }

  void exitFullScreen() {
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
  }

  void listenToFullScreenChange(void Function(SystemUIChangeType) onChange) {
    SystemChrome.setSystemUIChangeCallback((overlayVisible) async {
      return onChange(
        overlayVisible
            ? SystemUIChangeType.showSystemOverlays
            : SystemUIChangeType.hideSystemOverlays,
      );
    });
  }

  void dispose() {
    SystemChrome.setSystemUIChangeCallback(null);
  }
}

FullScreenManagerImpl createFullScreenManager() => FullScreenManagerImpl();
