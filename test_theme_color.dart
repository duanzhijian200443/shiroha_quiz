import 'package:flutter/material.dart';
import 'package:shiroha_quiz/ui/theme/app_theme.dart';

void main() {
  var theme = AppTheme.lightTheme;
  print('bodyLarge color: ${theme.textTheme.bodyLarge?.color}');
  print('bodyMedium color: ${theme.textTheme.bodyMedium?.color}');
  print('onSurface: ${theme.colorScheme.onSurface}');
}
