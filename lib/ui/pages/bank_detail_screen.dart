import 'answer_completion_screen.dart';
import '../dependencies/answer_completion_dependencies_scope.dart';
import 'package:flutter/material.dart';
import 'practice_page.dart';
import '../../application/study_activity/study_activity_contracts.dart';
import '../../domain/study_activity/study_activity_values.dart';
import '../study_activity/study_activity_route_binding.dart';
import 'question_list_screen.dart';
import '../../application/questions/question_list_query_port.dart';
import '../../application/questions/question_mutation_command.dart';
import '../../application/questions/question_bank_mutation_command.dart';
import '../dependencies/practice_command_dependencies.dart';
import '../../application/safe_write/typed_answer_command.dart';
import '../home/today_visual_theme.dart';
import '../theme/design_tokens.dart';

class BankDetailScreen extends StatefulWidget {
  final String bankName;
  final QuestionListQueryPort? questionListQuery;
  final QuestionMutationPersistencePort? questionMutationPersistence;
  final TypedAnswerPersistencePort? typedAnswerPersistence;
  final QuestionBankMutationPersistencePort? questionBankMutationPersistence;

  @visibleForTesting
  final QuestionBankMutationCommand? questionBankMutation;

  /// Assembled practice mutation commands, forwarded to the practice page.
  final PracticeCommandDependencies? practiceCommands;

  const BankDetailScreen({
    super.key,
    required this.bankName,
    this.questionListQuery,
    this.questionMutationPersistence,
    this.typedAnswerPersistence,
    this.questionBankMutationPersistence,
    this.questionBankMutation,
    this.practiceCommands,
  });

  @override
  State<BankDetailScreen> createState() => _BankDetailScreenState();
}

class _BankDetailScreenState extends State<BankDetailScreen> {
  QuestionBankMutationCommand get _questionBankMutation =>
      widget.questionBankMutation ??
      QuestionBankMutationCommand(_requireQuestionBankMutationPersistence);

  QuestionBankMutationPersistencePort
      get _requireQuestionBankMutationPersistence {
    final port = widget.questionBankMutationPersistence;
    if (port == null) {
      throw StateError('Question-bank mutation dependency is not configured.');
    }
    return port;
  }

  void _startPractice(BuildContext context, int? filterType) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PracticePage(
          studyActivity: StudyActivityRouteDescriptor(
              scene: StudyActivityScene.ordinaryPractice,
              context: StudyActivityContext(bankName: widget.bankName)),
          bankName: widget.bankName,
          filterType: filterType,
          practiceCommands: widget.practiceCommands,
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除题库'),
        content: Text('将永久删除题库「${widget.bankName}」中的 Questions 及允许级联的题目状态和复习数据；'
            'AnswerAttempt 历史作答记录保留。LibraryFile、ParsedArtifact、Project、'
            'ExamPaper 不会被级联删除；如有 ExamPaper 引用，删除会被阻止。'
            '此操作不可撤销。\n\n建议先导出 B0 备份。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                await _questionBankMutation.deleteQuestionBank(widget.bankName);
                if (!context.mounted) return;
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('题库已删除')));
                Navigator.pop(context);
              } catch (_) {
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('删除题库失败，请稍后重试')));
              }
            },
            child: const Text('彻底删除',
                style: TextStyle(
                    color: Colors.redAccent, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Theme(
      data: todayVisualTheme(Theme.of(context)),
      child: Builder(builder: _page));

  Widget _page(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final answerCompletion = AnswerCompletionDependenciesScope.maybeOf(context);
    return Scaffold(
        appBar: AppBar(
            leading: const BackButton(),
            backgroundColor: Colors.transparent,
            scrolledUnderElevation: 0,
            actions: [
              PopupMenuButton<String>(
                  key: const ValueKey('bank-detail-menu'),
                  tooltip: '更多操作',
                  icon: const Icon(Icons.more_vert_rounded),
                  onSelected: (_) => _confirmDelete(context),
                  itemBuilder: (_) => [
                        PopupMenuItem(
                            value: 'delete',
                            child: Text('删除题库',
                                style: TextStyle(color: colors.error)))
                      ])
            ]),
        body: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
                constraints: const BoxConstraints(
                    maxWidth: DesignTokens.contentMaxWidth),
                child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _BankDetailHeader(bankName: widget.bankName),
                          const _BankDetailSection(
                              title: '开始练习', subtitle: '智能规划，高效提升'),
                          _BankDetailActionCard(
                              key: const ValueKey('bank-practice-all'),
                              prominent: true,
                              icon: Icons.track_changes_rounded,
                              title: '全类型自适应复习',
                              subtitle: '智能混排，全面提升',
                              onTap: () => _startPractice(context, null)),
                          const SizedBox(height: DesignTokens.sectionGap),
                          const _BankDetailSection(
                              title: '专项练习', subtitle: '针对性突破，夯实每一类题型'),
                          _BankDetailActionCard(
                              key: const ValueKey('bank-practice-choice'),
                              icon: Icons.assignment_outlined,
                              title: '选择题专项',
                              subtitle: '单选多选集中突破',
                              onTap: () => _startPractice(context, 0)),
                          _BankDetailActionCard(
                              key: const ValueKey('bank-practice-fill'),
                              icon: Icons.edit_outlined,
                              title: '填空题专项',
                              subtitle: '精准记忆，不留死角',
                              onTap: () => _startPractice(context, 2)),
                          _BankDetailActionCard(
                              key: const ValueKey('bank-practice-short'),
                              icon: Icons.draw_outlined,
                              title: '简答题专项',
                              subtitle: '主观题深度思考',
                              onTap: () => _startPractice(context, 3)),
                          const SizedBox(height: DesignTokens.sectionGap),
                          const _BankDetailSection(
                              title: '题库管理', subtitle: '管理题库内容，完善你的学习资料'),
                          _BankDetailActionCard(
                              key: const ValueKey('bank-browse'),
                              icon: Icons.menu_book_outlined,
                              title: '浏览题库内容',
                              subtitle: '上帝视角查看所有题目与解析',
                              onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) => QuestionListScreen(
                                          bankName: widget.bankName,
                                          questionListQuery:
                                              widget.questionListQuery,
                                          questionMutationPersistence: widget
                                              .questionMutationPersistence,
                                          typedAnswerPersistence:
                                              widget.typedAnswerPersistence)))),
                          if (answerCompletion != null)
                            _BankDetailActionCard(
                                key: const ValueKey('bank-answer-completion'),
                                icon: Icons.layers_outlined,
                                title: '补充答案',
                                subtitle: '查看待补答案的题组与未分组题目',
                                onTap: () => Navigator.push(
                                    context,
                                    MaterialPageRoute<void>(
                                        builder: (_) => AnswerCompletionScreen(
                                            bankName: widget.bankName)))),
                        ])))));
  }
}

class _BankDetailHeader extends StatelessWidget {
  const _BankDetailHeader({required this.bankName});
  final String bankName;
  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final colors = Theme.of(context).colorScheme;
        final decorate = constraints.maxWidth >= 300 &&
            MediaQuery.textScalerOf(context).scale(14) < 21;
        final artWidth = constraints.maxWidth >= 500 ? 160.0 : 120.0;
        return SizedBox(
            width: double.infinity,
            child: Stack(children: [
              if (decorate)
                Positioned(
                    right: 0,
                    top: 0,
                    child: IgnorePointer(
                        child: ExcludeSemantics(
                            child: Opacity(
                                opacity: .28,
                                child: Image.asset(
                                    'assets/images/today/paper-pencil.png',
                                    width: artWidth,
                                    height: 112,
                                    fit: BoxFit.contain,
                                    cacheWidth: 320))))),
              Padding(
                  padding: EdgeInsets.only(
                      top: 12, bottom: 32, right: decorate ? artWidth - 12 : 0),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(bankName,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .headlineLarge
                                ?.copyWith(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 8),
                        Text('选择适合自己的训练方式',
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(color: colors.onSurfaceVariant)),
                      ])),
            ]));
      });
}

class _BankDetailSection extends StatelessWidget {
  const _BankDetailSection({required this.title, required this.subtitle});
  final String title, subtitle;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title,
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 5),
        Text(subtitle,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ]));
}

class _BankDetailActionCard extends StatelessWidget {
  const _BankDetailActionCard(
      {super.key,
      required this.icon,
      required this.title,
      required this.subtitle,
      required this.onTap,
      this.prominent = false});
  final IconData icon;
  final String title, subtitle;
  final VoidCallback onTap;
  final bool prominent;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(DesignTokens.cardRadius + 6);
    return Card(
        elevation: 1,
        surfaceTintColor: Colors.transparent,
        shadowColor: colors.shadow.withValues(alpha: .06),
        margin: const EdgeInsets.only(bottom: 12),
        shape: RoundedRectangleBorder(
            borderRadius: radius,
            side:
                BorderSide(color: colors.outlineVariant.withValues(alpha: .6))),
        child: Semantics(
            button: true,
            child: InkWell(
                onTap: onTap,
                borderRadius: radius,
                child: Padding(
                    padding: EdgeInsets.symmetric(
                        horizontal: 18, vertical: prominent ? 20 : 14),
                    child: Row(children: [
                      Container(
                          width: prominent ? 54 : 44,
                          height: prominent ? 54 : 44,
                          decoration: BoxDecoration(
                              color: colors.surfaceContainerHighest,
                              borderRadius:
                                  BorderRadius.circular(prominent ? 27 : 14)),
                          child: ExcludeSemantics(
                              child: Icon(icon,
                                  size: prominent ? 30 : 26,
                                  color: colors.onSurface))),
                      const SizedBox(width: 16),
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text(title,
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w700)),
                            const SizedBox(height: 5),
                            Text(subtitle,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                        color: colors.onSurfaceVariant,
                                        height: 1.5)),
                          ])),
                      const SizedBox(width: 8),
                      Icon(Icons.chevron_right_rounded,
                          color: colors.onSurfaceVariant),
                    ])))));
  }
}
