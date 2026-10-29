import 'fullscreen_manager_types.dart';

class FullScreenManagerImpl {
  void enterFullScreen() {}
  void exitFullScreen() {}
  void listenToFullScreenChange(void Function(SystemUIChangeType) onChange) {}
  void dispose() {}
}

FullScreenManagerImpl createFullScreenManager() => FullScreenManagerImpl();
