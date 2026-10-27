import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

void showSnackBar(
  String message,
  BuildContext context, {
  Duration? duration,
  Widget? leading,
  SnackBarAction? action,
  Color? backgroundColor,
  TextStyle? textStyle,
  bool showCloseButton = false,
  bool waitCurrentFrameToComplete = false,
}) {
  final theme = Theme.of(context);
  final snackBar = SnackBar(
    duration: duration ?? const Duration(milliseconds: 5000),
    content: Center(
      child: Card(
        elevation: 8,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        color: backgroundColor ?? theme.colorScheme.surfaceContainerLow,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (leading != null) ...[leading, const SizedBox(width: 8)],
              Flexible(child: Text(message, style: textStyle)),
              if (action != null) ...[const SizedBox(width: 20), action],
              if (showCloseButton)
                IconButton(
                  icon: Icon(Symbols.close, size: 20),
                  onPressed: () {
                    ScaffoldMessenger.of(context).hideCurrentSnackBar();
                  },
                ),
            ],
          ),
        ),
      ),
    ),
    // action: action,
    behavior: SnackBarBehavior.floating,
    backgroundColor: Colors.transparent,
    elevation: 0,
  );

  if (waitCurrentFrameToComplete) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(snackBar);
    });
  } else {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(snackBar);
  }
}

void showSuccessSnackBar(
  String message,
  BuildContext context, {
  Duration? duration,
  SnackBarAction? action,
  bool showCloseButton = false,
  bool waitCurrentFrameToComplete = false,
}) {
  showSnackBar(
    message,
    context,
    duration: duration,
    action: action,
    leading: Icon(Symbols.check_circle, color: Colors.green, size: 20),
    showCloseButton: showCloseButton,
    waitCurrentFrameToComplete: waitCurrentFrameToComplete,
  );
}

void showErrorSnackBar(
  String message,
  BuildContext context, {
  Duration? duration,
  SnackBarAction? action,
  bool showCloseButton = false,
  bool waitCurrentFrameToComplete = false,
}) {
  showSnackBar(
    message,
    context,
    duration: duration,
    action: action,
    leading: Icon(Symbols.error, color: Colors.red, size: 20),
    showCloseButton: showCloseButton,
    waitCurrentFrameToComplete: waitCurrentFrameToComplete,
  );
}

void showInfoSnackBar(
  String message,
  BuildContext context, {
  Duration? duration,
  SnackBarAction? action,
  bool showCloseButton = false,
  bool waitCurrentFrameToComplete = false,
}) {
  showSnackBar(
    message,
    context,
    duration: duration,
    action: action,
    leading: Icon(Symbols.info, color: Colors.blue, size: 20),
    showCloseButton: showCloseButton,
    waitCurrentFrameToComplete: waitCurrentFrameToComplete,
  );
}

void showWarningSnackBar(
  String message,
  BuildContext context, {
  Duration? duration,
  SnackBarAction? action,
  bool showCloseButton = false,
  bool waitCurrentFrameToComplete = false,
}) {
  showSnackBar(
    message,
    context,
    duration: duration,
    action: action,
    leading: Icon(Symbols.warning, color: Colors.orange, size: 20),
    showCloseButton: showCloseButton,
    waitCurrentFrameToComplete: waitCurrentFrameToComplete,
  );
}
