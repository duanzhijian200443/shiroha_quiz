import 'package:flutter/material.dart';

import '../theme/design_tokens.dart';

class ShirohaPageBody extends StatelessWidget {
  const ShirohaPageBody({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: DesignTokens.contentMaxWidth,
          ),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              DesignTokens.pageHorizontalPadding,
              DesignTokens.pageHorizontalPadding,
              DesignTokens.pageHorizontalPadding,
              DesignTokens.pageBottomPadding,
            ),
            children: children,
          ),
        ),
      ),
    );
  }
}

class ShirohaSectionLabel extends StatelessWidget {
  const ShirohaSectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        text,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class ShirohaSurfaceCard extends StatelessWidget {
  const ShirohaSurfaceCard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(DesignTokens.cardRadius),
        border: Border.all(color: theme.colorScheme.outlineVariant),
        boxShadow: DesignTokens.surfaceShadow(theme.brightness),
      ),
      child: child,
    );
  }
}

class ShirohaSettingsCard extends StatelessWidget {
  const ShirohaSettingsCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final dividerColor = Theme.of(context).colorScheme.outlineVariant;
    return ShirohaSurfaceCard(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(DesignTokens.cardRadius),
        child: Column(
          children: <Widget>[
            for (var index = 0; index < children.length; index++) ...<Widget>[
              if (index > 0)
                Divider(
                  height: 1,
                  thickness: 1,
                  indent: 64,
                  color: dividerColor,
                ),
              children[index],
            ],
          ],
        ),
      ),
    );
  }
}
