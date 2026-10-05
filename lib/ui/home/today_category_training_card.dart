import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../application/training/today_training_contracts.dart';
import '../../application/training/training_contracts.dart';
import '../../application/home_training_result.dart';
import '../../domain/training/category_key.dart';
import '../training/training_visuals.dart';

/// Category pages consume captured view facts; scrolling itself never writes.
class TodayCategoryTrainingCard extends StatefulWidget {
  const TodayCategoryTrainingCard(
      {super.key,
      required this.snapshot,
      required this.category,
      required this.busy,
      required this.onCategory,
      required this.onCycle,
      required this.onConfig});
  final TodayTrainingSnapshot snapshot;
  final TrainingCategorySnapshot? category;
  final bool busy;
  final ValueChanged<CategoryKey> onCategory;
  final VoidCallback onCycle;
  final VoidCallback onConfig;
  @override
  State<TodayCategoryTrainingCard> createState() => _CategoryCardState();
}

class _CategoryCardState extends State<TodayCategoryTrainingCard> {
  late PageController _pages;
  bool _dragging = false;
  int get _index => widget.snapshot.categories
      .indexOf(widget.snapshot.selection.categoryKey!);
  @override
  void initState() {
    super.initState();
    _pages = PageController(
        initialPage: _index,
        viewportFraction: widget.snapshot.categories.length == 1 ? 1 : .83);
  }

  @override
  void didUpdateWidget(TodayCategoryTrainingCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final countChanged = oldWidget.snapshot.categories.length !=
        widget.snapshot.categories.length;
    if (countChanged) {
      final old = _pages;
      _pages = PageController(
          initialPage: _index,
          viewportFraction: widget.snapshot.categories.length == 1 ? 1 : .83);
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _pages.hasClients &&
            !_dragging &&
            (_pages.page! - _index).abs() > .01) {
          _pages.jumpToPage(_index);
        }
      });
    }
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final keys = widget.snapshot.categories;
    final selection = widget.snapshot.selection;
    final current = selection.currentContent?.content;
    final usable = widget.category?.contents.where((v) => v.usable).length ?? 0;
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth * (keys.length == 1 ? 1 : .83) -
          (keys.length > 1 ? 10 : 0) -
          96;
      double heightOf(String text, TextStyle? style) {
        final painter = TextPainter(
            text: TextSpan(text: text, style: style),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context))
          ..layout(maxWidth: math.max(1, width));
        final height = painter.height;
        painter.dispose();
        return height;
      }

      final titleStyle = Theme.of(context)
          .textTheme
          .headlineSmall
          ?.copyWith(fontWeight: FontWeight.w700);
      final contentTitle = current?.name ??
          (selection.state == TrainingCurrentContentState.unavailable
              ? '训练配置需修复'
              : '未配置');
      final titleHeight = keys
          .map((k) => heightOf(trainingCategoryLabel(k), titleStyle))
          .reduce(math.max);
      final cardHeight = math.max(
          174.0,
          42 +
              titleHeight +
              10 +
              heightOf(contentTitle, Theme.of(context).textTheme.titleMedium) +
              (current == null ? 80 : 0));
      return Column(children: [
        SizedBox(
            height: cardHeight,
            child: NotificationListener<ScrollNotification>(
              onNotification: (notice) {
                if (notice is ScrollStartNotification &&
                    notice.dragDetails != null) {
                  _dragging = true;
                }
                if (notice is ScrollEndNotification && _dragging) {
                  _dragging = false;
                  final settled = (_pages.page ?? _index.toDouble()).round();
                  if (!widget.busy && settled != _index) {
                    widget.onCategory(keys[settled]);
                  }
                  // A rejected/ignored swipe must also return to authoritative state.
                  if (widget.busy && _pages.hasClients) {
                    _pages.jumpToPage(_index);
                  }
                }
                return false;
              },
              child: PageView.builder(
                key: const ValueKey('home-category-pages'),
                controller: _pages,
                padEnds: false,
                physics: widget.busy || keys.length == 1
                    ? const NeverScrollableScrollPhysics()
                    : null,
                itemCount: keys.length,
                itemBuilder: (context, index) {
                  final key = keys[index];
                  final isCurrent = key == selection.categoryKey;
                  return Semantics(
                      label:
                          '分类 ${trainingCategoryLabel(key)}，第${index + 1}页，共${keys.length}页',
                      child: Padding(
                          padding:
                              EdgeInsets.only(right: keys.length > 1 ? 10 : 0),
                          child: Container(
                            decoration: BoxDecoration(
                                color: colors.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(18)),
                            child: Stack(children: [
                              Positioned(
                                  right: 18,
                                  bottom: 16,
                                  child: Opacity(
                                      opacity: .7,
                                      child: Transform.scale(
                                          scale: 1.5,
                                          child: CategoryVisualBadge(
                                              visualKey: isCurrent
                                                  ? widget.category?.preference
                                                      .visualKey
                                                  : null,
                                              label: trainingCategoryLabel(
                                                  key))))),
                              Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(18, 26, 78, 16),
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(trainingCategoryLabel(key),
                                            style: Theme.of(context)
                                                .textTheme
                                                .headlineSmall
                                                ?.copyWith(
                                                    fontWeight:
                                                        FontWeight.w700)),
                                        if (isCurrent) ...[
                                          const SizedBox(height: 10),
                                          AnimatedSwitcher(
                                              duration: MediaQuery
                                                      .disableAnimationsOf(
                                                          context)
                                                  ? Duration.zero
                                                  : const Duration(
                                                      milliseconds: 200),
                                              child: Text(
                                                  current?.name ??
                                                      (selection.state ==
                                                              TrainingCurrentContentState
                                                                  .unavailable
                                                          ? '训练配置需修复'
                                                          : '未配置'),
                                                  key: ValueKey(
                                                      current?.contentId),
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .titleMedium)),
                                          if (current == null)
                                            TextButton(
                                                onPressed: widget.busy
                                                    ? null
                                                    : widget.onConfig,
                                                child: const Text('配置训练内容')),
                                        ],
                                      ])),
                              if (isCurrent && usable > 1)
                                Positioned(
                                    right: 0,
                                    top: 0,
                                    child: FoldedPageCorner(
                                        onPressed: widget.busy
                                            ? null
                                            : widget.onCycle)),
                            ]),
                          )));
                },
              ),
            )),
        if (keys.length > 1)
          Padding(
              padding: const EdgeInsets.only(top: 8),
              child:
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                for (var i = 0; i < keys.length; i++)
                  Semantics(
                      label: '分类第${i + 1}页',
                      selected: i == _index,
                      child: Container(
                          key: ValueKey('home-category-dot-$i'),
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          width: i == _index ? 10 : 7,
                          height: i == _index ? 10 : 7,
                          decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: i == _index
                                  ? colors.onSurface
                                  : colors.outlineVariant))),
              ])),
      ]);
    });
  }
}

class FoldedPageCorner extends StatelessWidget {
  const FoldedPageCorner({super.key, this.onPressed});
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => Semantics(
      label: '切换下一个训练内容',
      button: true,
      enabled: onPressed != null,
      child: InkWell(
          key: const ValueKey('home-content-corner'),
          onTap: onPressed,
          borderRadius: const BorderRadius.only(topRight: Radius.circular(18)),
          child: SizedBox(
              width: 48,
              height: 48,
              child: CustomPaint(
                  painter: _CornerPainter(Theme.of(context).colorScheme)))));
}

class _CornerPainter extends CustomPainter {
  _CornerPainter(this.colors);
  final ColorScheme colors;
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, size.height)
      ..quadraticBezierTo(12, size.height - 6, 0, 0)
      ..close();
    canvas.drawShadow(path, colors.shadow.withValues(alpha: .15), 2, false);
    canvas.drawPath(path, Paint()..color = colors.surface);
  }

  @override
  bool shouldRepaint(_CornerPainter old) => old.colors != colors;
}

class TodayTrainingActionCard extends StatelessWidget {
  const TodayTrainingActionCard(
      {super.key,
      required this.title,
      required this.count,
      required this.icon,
      required this.enabled,
      this.onPressed});
  final String title;
  final HomeTrainingResult<TrainingCount>? count;
  final IconData icon;
  final bool enabled;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) {
    final value = switch (count) {
      HomeTrainingSuccess(:final value) => '${value.value}',
      _ => '—'
    };
    final colors = Theme.of(context).colorScheme;
    return Semantics(
        button: true,
        enabled: enabled,
        label: '$title $value题${enabled ? '' : '，不可开始'}',
        child: Material(
            color: colors.surface,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: colors.outlineVariant)),
            child: InkWell(
                onTap: enabled ? onPressed : null,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Icon(icon,
                                size: 28,
                                color: enabled
                                    ? colors.onSurface
                                    : colors.outline),
                            const Spacer(),
                            const Icon(Icons.chevron_right_rounded, size: 18)
                          ]),
                          const SizedBox(height: 10),
                          Text('$value 题',
                              style: TextStyle(
                                  fontSize: 22,
                                  color: enabled
                                      ? colors.onSurface
                                      : colors.onSurfaceVariant)),
                          Text(title,
                              style: Theme.of(context).textTheme.bodySmall),
                        ])))));
  }
}
