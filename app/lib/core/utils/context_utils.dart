import 'package:flutter/widgets.dart';

extension ContextUtils on BuildContext {
  bool get isSmallScreen => MediaQuery.sizeOf(this).width <= 600;
}
