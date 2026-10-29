enum SystemUIChangeType {
  enterFullScreen,
  exitFullScreen,
  showSystemOverlays,
  hideSystemOverlays;

  bool get isOverlayChange =>
      this == SystemUIChangeType.showSystemOverlays ||
      this == SystemUIChangeType.hideSystemOverlays;
}
