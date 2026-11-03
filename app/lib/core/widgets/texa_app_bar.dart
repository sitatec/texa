import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:texa/core/utils/context_utils.dart';
import 'package:texa/core/widgets/texa_logo.dart';

class TexaAppBar extends StatelessWidget implements PreferredSizeWidget {
  final Widget? title;
  final PreferredSizeWidget? bottom;
  final bool automaticallyImplyLeading;
  final bool centerTitle;
  final Widget? leading;
  final double height;
  final double maxWidth;
  final double? titleSpacing;
  final List<Widget>? actions;

  const TexaAppBar({
    super.key,
    this.bottom,
    this.title,
    this.automaticallyImplyLeading = true,
    this.centerTitle = false,
    this.leading,
    this.height = 48,
    this.maxWidth = double.infinity,
    this.actions,
    this.titleSpacing,
  });

  @override
  Size get preferredSize {
    double appBarHeight = height;
    if (bottom != null) {
      appBarHeight += bottom!.preferredSize.height;
    }
    return Size.fromHeight(appBarHeight);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final systemOverlayBrightness = defaultTargetPlatform == .iOS
        ? theme.brightness
        : theme.brightness == Brightness.light
        ? Brightness.dark
        : Brightness.light;
    final canShowImplicitLeading =
        automaticallyImplyLeading && Navigator.canPop(context) == true;
    final isSmallScreen = context.isSmallScreen;

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: AppBar(
          automaticallyImplyLeading: false,
          systemOverlayStyle: SystemUiOverlayStyle(
            statusBarColor: theme.colorScheme.surface,
            statusBarIconBrightness: systemOverlayBrightness,
            statusBarBrightness: systemOverlayBrightness,
            systemNavigationBarColor: theme.colorScheme.surface,
            systemNavigationBarIconBrightness: systemOverlayBrightness,
          ),
          shadowColor: Colors.transparent,
          // elevation: 0,
          centerTitle: centerTitle,
          foregroundColor: theme.colorScheme.onSurface,
          backgroundColor: theme.colorScheme.surface,
          titleTextStyle: theme.textTheme.bodyLarge?.copyWith(fontSize: 18),
          leading:
              leading ??
              (canShowImplicitLeading
                  ? Transform.scale(scale: 0.8, child: BackButton())
                  : null),
          titleSpacing: titleSpacing ?? (isSmallScreen ? 8 : 16),
          title:
              title ??
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: TexaLogo(),
              ),
          bottom: bottom,
          actions: [
            ...?actions,
            SizedBox(width: isSmallScreen ? 8 : 16),
          ],
        ),
      ),
    );
  }
}
