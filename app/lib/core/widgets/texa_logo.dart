import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';

class TexaLogo extends StatelessWidget {
  final double scale;
  final Color? textColor;
  final bool symbolOnly;
  final bool navigateHomeOnWeb;

  const TexaLogo({
    super.key,
    this.scale = 1.3,
    this.textColor,
    this.symbolOnly = false,
    this.navigateHomeOnWeb = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      alignment: .centerStart,
      clipBehavior: .none,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 1.7),
          child: SvgPicture.string(
            """<svg viewBox="0 0 900 1060"><g><path d="M320 50h380a130 130 0 0 1 0 260H600A260 260 0 0 0 320 50" style="fill:#fbbf24"/><path d="M170 50h250a360 260 0 0 1 180 260H170a130 130 0 0 1 0-260" style="fill:#10b981"/><path d="M220 310h380v330c-90 60-210-40-280 0V410a100 100 0 0 0-100-100" style="fill:#ef6666"/><path d="M320 440c170 40 190-40 280-130v470a130 130 0 0 1-280 0Z" style="fill:#3b82f6"/></g></svg>""",
            height: 23 * scale,
          ),
        ),
        if (!symbolOnly)
          PositionedDirectional(
            start: 19,
            child: Text(
              "exa",
              style: theme.textTheme.titleLarge?.copyWith(
                color:
                    textColor ??
                    theme.colorScheme.onSurface.withValues(alpha: 0.9),
                fontSize: 22 * (scale * 0.98),
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
      ],
    );
  }
}
