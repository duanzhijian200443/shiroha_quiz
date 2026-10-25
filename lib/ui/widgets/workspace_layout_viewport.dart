import 'dart:ui' show DisplayFeature;

import 'package:flutter/material.dart';

import '../theme/design_tokens.dart';
import '../theme/shiroha_theme_tokens.dart';

/// Scales the desktop canvas, including Navigator routes and overlay anchors.
/// The tree stays in the same slot when switching back to the mobile layout.
class WorkspaceLayoutViewport extends StatelessWidget {
  const WorkspaceLayoutViewport({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final workspace =
        Theme.of(context).extension<ShirohaThemeTokens>()?.appearance.layout ==
            ShirohaLayoutMode.workspace;
    final media = MediaQuery.of(context);
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      final scale = workspace && width > 0
          ? (width / DesignTokens.workspaceReferenceWidth).clamp(0.0, 1.0)
          : 1.0;
      final size = Size(width / scale, constraints.maxHeight / scale);
      final logicalMedia = media.copyWith(
        size: size,
        padding: media.padding / scale,
        viewPadding: media.viewPadding / scale,
        viewInsets: media.viewInsets / scale,
        systemGestureInsets: media.systemGestureInsets / scale,
        displayFeatures: [
          for (final feature in media.displayFeatures)
            DisplayFeature(
              bounds: Rect.fromLTRB(
                feature.bounds.left / scale,
                feature.bounds.top / scale,
                feature.bounds.right / scale,
                feature.bounds.bottom / scale,
              ),
              type: feature.type,
              state: feature.state,
            ),
        ],
      );
      return SizedBox.expand(
        child: FittedBox(
          fit: BoxFit.contain,
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: MediaQuery(data: logicalMedia, child: child),
          ),
        ),
      );
    });
  }
}
