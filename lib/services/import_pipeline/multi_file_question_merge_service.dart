import '../../data/models/question_identity.dart';

enum QuestionBatchRole {
  stemDominant,
  answerDominant,
  mixed,
  ambiguous,
}

enum MultiFileQuestionConflictKind {
  duplicateQuestionNumber,
  stem,
  answer,
}

class MultiFileQuestionBatch {
  const MultiFileQuestionBatch({
    required this.fileIndex,
    required this.questions,
  });

  final int fileIndex;
  final List<Map<String, dynamic>> questions;
}

class QuestionBatchProfile {
  const QuestionBatchProfile({
    required this.fileIndex,
    required this.role,
    required this.validStemRatio,
    required this.completeOptionsRatio,
    required this.answerRatio,
    required this.explanationRatio,
  });

  final int fileIndex;
  final QuestionBatchRole role;
  final double validStemRatio;
  final double completeOptionsRatio;
  final double answerRatio;
  final double explanationRatio;

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'fileIndex': fileIndex,
      'role': role.name,
      'validStemRatio': validStemRatio,
      'completeOptionsRatio': completeOptionsRatio,
      'answerRatio': answerRatio,
      'explanationRatio': explanationRatio,
    };
  }
}

class MultiFileQuestionResidual {
  const MultiFileQuestionResidual({
    required this.fragmentId,
    required this.fileIndex,
    required this.questionIndex,
    required this.questionNumber,
    required this.question,
  });

  final String fragmentId;
  final int fileIndex;
  final int questionIndex;
  final int? questionNumber;
  final Map<String, dynamic> question;
}

class MultiFileQuestionConflict {
  const MultiFileQuestionConflict({
    required this.kind,
    required this.questionNumber,
    required this.fragmentIds,
  });

  final MultiFileQuestionConflictKind kind;
  final int questionNumber;
  final List<String> fragmentIds;

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'kind': kind.name,
      'questionNumber': questionNumber,
      'fragmentIds': fragmentIds,
    };
  }
}

class MultiFileQuestionMergeMetrics {
  const MultiFileQuestionMergeMetrics({
    required this.inputFileCount,
    required this.parsedQuestionCountByFile,
    required this.exactQuestionNumberBucketCount,
    required this.mergedQuestionCount,
    required this.answerOnlyMergeCount,
    required this.duplicateKeyCount,
    required this.stemConflictCount,
    required this.answerConflictCount,
    required this.unmatchedFragmentCount,
    required this.finalQuestionCount,
    required this.requiresReview,
    required this.blocked,
  });

  final int inputFileCount;
  final Map<int, int> parsedQuestionCountByFile;
  final int exactQuestionNumberBucketCount;
  final int mergedQuestionCount;
  final int answerOnlyMergeCount;
  final int duplicateKeyCount;
  final int stemConflictCount;
  final int answerConflictCount;
  final int unmatchedFragmentCount;
  final int finalQuestionCount;
  final bool requiresReview;
  final bool blocked;

  Map<String, dynamic> toMap() {
    final fileCounts = parsedQuestionCountByFile.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return <String, dynamic>{
      'inputFileCount': inputFileCount,
      'parsedQuestionCountByFile': fileCounts
          .map(
            (entry) => <String, int>{
              'fileIndex': entry.key,
              'questionCount': entry.value,
            },
          )
          .toList(growable: false),
      'exactQuestionNumberBucketCount': exactQuestionNumberBucketCount,
      'mergedQuestionCount': mergedQuestionCount,
      'answerOnlyMergeCount': answerOnlyMergeCount,
      'duplicateKeyCount': duplicateKeyCount,
      'stemConflictCount': stemConflictCount,
      'answerConflictCount': answerConflictCount,
      'unmatchedFragmentCount': unmatchedFragmentCount,
      'finalQuestionCount': finalQuestionCount,
      'requiresReview': requiresReview,
      'blocked': blocked,
    };
  }
}

class MultiFileQuestionMergeResult {
  const MultiFileQuestionMergeResult({
    required this.mergedQuestions,
    required this.residualFragments,
    required this.conflictFragments,
    required this.batchProfiles,
    required this.metrics,
    required this.requiresReview,
    required this.blocked,
  });

  final List<Map<String, dynamic>> mergedQuestions;
  final List<MultiFileQuestionResidual> residualFragments;
  final List<MultiFileQuestionConflict> conflictFragments;
  final List<QuestionBatchProfile> batchProfiles;
  final MultiFileQuestionMergeMetrics metrics;
  final bool requiresReview;
  final bool blocked;
}

class MultiFileQuestionMergeService {
  const MultiFileQuestionMergeService();

  MultiFileQuestionMergeResult merge(
    List<MultiFileQuestionBatch> batches,
  ) {
    final sortedBatches = [...batches]
      ..sort((a, b) => a.fileIndex.compareTo(b.fileIndex));
    final profiles = sortedBatches.map(_profileBatch).toList(growable: false);
    final profilesByFile = <int, QuestionBatchProfile>{
      for (final profile in profiles) profile.fileIndex: profile,
    };
    final parsedQuestionCountByFile = <int, int>{};
    final buckets = <int, List<_QuestionFragment>>{};
    final residuals = <MultiFileQuestionResidual>[];

    for (final batch in sortedBatches) {
      parsedQuestionCountByFile.update(
        batch.fileIndex,
        (count) => count + batch.questions.length,
        ifAbsent: () => batch.questions.length,
      );
      for (var questionIndex = 0;
          questionIndex < batch.questions.length;
          questionIndex++) {
        final question = batch.questions[questionIndex];
        final number = _readQuestionNumber(question);
        final fragment = _QuestionFragment(
          fileIndex: batch.fileIndex,
          questionIndex: questionIndex,
          questionNumber: number,
          raw: question,
          profile: profilesByFile[batch.fileIndex]!,
        );
        if (number == null) {
          residuals.add(fragment.toResidual());
        } else {
          buckets
              .putIfAbsent(number, () => <_QuestionFragment>[])
              .add(fragment);
        }
      }
    }

    final mergedQuestions = <Map<String, dynamic>>[];
    final conflicts = <MultiFileQuestionConflict>[];
    var exactQuestionNumberBucketCount = 0;
    var answerOnlyMergeCount = 0;
    var duplicateKeyCount = 0;
    var stemConflictCount = 0;
    var answerConflictCount = 0;

    final sortedNumbers = buckets.keys.toList()..sort();
    for (final number in sortedNumbers) {
      final fragments = buckets[number]!
        ..sort(_compareFragmentsBySourcePosition);
      final distinctFiles = fragments.map((item) => item.fileIndex).toSet();
      if (distinctFiles.length < 2) {
        residuals.addAll(fragments.map((fragment) => fragment.toResidual()));
        continue;
      }
      exactQuestionNumberBucketCount++;

      final hasDuplicateWithinFile = _hasDuplicateWithinFile(fragments);
      if (hasDuplicateWithinFile) {
        duplicateKeyCount++;
        conflicts.add(
          _conflict(
            MultiFileQuestionConflictKind.duplicateQuestionNumber,
            number,
            fragments,
          ),
        );
        residuals.addAll(fragments.map((fragment) => fragment.toResidual()));
        continue;
      }

      final stemCandidates = _authoritativeStemCandidates(fragments);
      final selectedStem = _selectCompatibleStem(stemCandidates);
      if (selectedStem == null) {
        stemConflictCount++;
        conflicts.add(
          _conflict(
            MultiFileQuestionConflictKind.stem,
            number,
            stemCandidates.isEmpty ? fragments : stemCandidates,
          ),
        );
        residuals.addAll(fragments.map((fragment) => fragment.toResidual()));
        continue;
      }

      final merged = Map<String, dynamic>.from(selectedStem.raw);
      merged['q_num'] = number.toString();
      merged['question_number'] = number;
      merged['content'] = _readString(selectedStem.raw['content']);
      merged['options'] = _selectOptions(fragments, selectedStem);

      final answerSelection = _selectAnswer(fragments);
      if (answerSelection.hasConflict) {
        answerConflictCount++;
        merged['standard_answer'] = '';
        conflicts.add(
          _conflict(
            MultiFileQuestionConflictKind.answer,
            number,
            answerSelection.fragments,
          ),
        );
      } else if (answerSelection.fragment != null) {
        merged['standard_answer'] =
            _readString(answerSelection.fragment!.raw['standard_answer']);
        if (answerSelection.fragment!.fragmentId != selectedStem.fragmentId &&
            (answerSelection.fragment!.profile.role ==
                    QuestionBatchRole.answerDominant ||
                !_hasValidStem(answerSelection.fragment!.raw))) {
          answerOnlyMergeCount++;
        }
      }

      final explanation = _selectExplanation(fragments);
      if (explanation != null) {
        merged['explanation'] = _readString(explanation.raw['explanation']);
        if (_hasNonEmptyString(explanation.raw['raw_explanation'])) {
          merged['raw_explanation'] = explanation.raw['raw_explanation'];
        }
      }

      _mergeProvenance(merged, fragments);
      mergedQuestions.add(merged);
    }

    residuals.sort((a, b) {
      final fileCompare = a.fileIndex.compareTo(b.fileIndex);
      if (fileCompare != 0) return fileCompare;
      return a.questionIndex.compareTo(b.questionIndex);
    });
    conflicts.sort((a, b) {
      final numberCompare = a.questionNumber.compareTo(b.questionNumber);
      if (numberCompare != 0) return numberCompare;
      return a.kind.index.compareTo(b.kind.index);
    });

    final requiresReview = residuals.isNotEmpty || conflicts.isNotEmpty;
    final blocked = requiresReview;
    final metrics = MultiFileQuestionMergeMetrics(
      inputFileCount: batches.length,
      parsedQuestionCountByFile:
          Map<int, int>.unmodifiable(parsedQuestionCountByFile),
      exactQuestionNumberBucketCount: exactQuestionNumberBucketCount,
      mergedQuestionCount: mergedQuestions.length,
      answerOnlyMergeCount: answerOnlyMergeCount,
      duplicateKeyCount: duplicateKeyCount,
      stemConflictCount: stemConflictCount,
      answerConflictCount: answerConflictCount,
      unmatchedFragmentCount: residuals.length,
      finalQuestionCount: mergedQuestions.length,
      requiresReview: requiresReview,
      blocked: blocked,
    );

    return MultiFileQuestionMergeResult(
      mergedQuestions: List<Map<String, dynamic>>.unmodifiable(mergedQuestions),
      residualFragments:
          List<MultiFileQuestionResidual>.unmodifiable(residuals),
      conflictFragments:
          List<MultiFileQuestionConflict>.unmodifiable(conflicts),
      batchProfiles: List<QuestionBatchProfile>.unmodifiable(profiles),
      metrics: metrics,
      requiresReview: requiresReview,
      blocked: blocked,
    );
  }

  QuestionBatchProfile _profileBatch(MultiFileQuestionBatch batch) {
    final total = batch.questions.length;
    if (total == 0) {
      return QuestionBatchProfile(
        fileIndex: batch.fileIndex,
        role: QuestionBatchRole.ambiguous,
        validStemRatio: 0,
        completeOptionsRatio: 0,
        answerRatio: 0,
        explanationRatio: 0,
      );
    }

    final validStemCount = batch.questions.where(_hasValidStem).length;
    final completeOptionsCount =
        batch.questions.where(_hasCompleteOptions).length;
    final answerCount = batch.questions
        .where((question) => _hasNonEmptyString(question['standard_answer']))
        .length;
    final explanationCount = batch.questions
        .where((question) => _hasNonEmptyString(question['explanation']))
        .length;

    final validStemRatio = validStemCount / total;
    final completeOptionsRatio = completeOptionsCount / total;
    final answerRatio = answerCount / total;
    final explanationRatio = explanationCount / total;
    final strongAnswer = answerRatio >= 0.6 &&
        (explanationRatio >= 0.25 || completeOptionsRatio < 0.25);
    final strongStem = validStemRatio >= 0.6 &&
        (completeOptionsRatio >= 0.25 ||
            (answerRatio < 0.4 && explanationRatio < 0.4));

    final QuestionBatchRole role;
    if (strongStem && !strongAnswer) {
      role = QuestionBatchRole.stemDominant;
    } else if (strongAnswer && !strongStem) {
      role = QuestionBatchRole.answerDominant;
    } else if (validStemRatio >= 0.5 &&
        (answerRatio >= 0.5 || explanationRatio >= 0.5)) {
      role = QuestionBatchRole.mixed;
    } else {
      role = QuestionBatchRole.ambiguous;
    }

    return QuestionBatchProfile(
      fileIndex: batch.fileIndex,
      role: role,
      validStemRatio: validStemRatio,
      completeOptionsRatio: completeOptionsRatio,
      answerRatio: answerRatio,
      explanationRatio: explanationRatio,
    );
  }

  int? _readQuestionNumber(Map<String, dynamic> question) {
    return QuestionIdentity.tryParseExplicitQuestionNumber(question['q_num']) ??
        QuestionIdentity.tryParseExplicitQuestionNumber(
          question['question_number'],
        );
  }

  bool _hasDuplicateWithinFile(List<_QuestionFragment> fragments) {
    final counts = <int, int>{};
    for (final fragment in fragments) {
      counts.update(fragment.fileIndex, (count) => count + 1,
          ifAbsent: () => 1);
    }
    return counts.values.any((count) => count > 1);
  }

  List<_QuestionFragment> _authoritativeStemCandidates(
    List<_QuestionFragment> fragments,
  ) {
    final withStem = fragments.where((fragment) => _hasValidStem(fragment.raw));
    final stemDominant = withStem
        .where(
          (fragment) => fragment.profile.role == QuestionBatchRole.stemDominant,
        )
        .toList();
    if (stemDominant.isNotEmpty) return stemDominant;

    final mixed = withStem
        .where(
          (fragment) => fragment.profile.role == QuestionBatchRole.mixed,
        )
        .toList();
    if (mixed.isNotEmpty) return mixed;
    return withStem.toList();
  }

  _QuestionFragment? _selectCompatibleStem(
    List<_QuestionFragment> candidates,
  ) {
    if (candidates.isEmpty) return null;
    final sorted = [...candidates]..sort((a, b) {
        final contentA = _normalizeComparableText(a.raw['content']);
        final contentB = _normalizeComparableText(b.raw['content']);
        final lengthCompare = contentB.length.compareTo(contentA.length);
        if (lengthCompare != 0) return lengthCompare;
        final textCompare = contentA.compareTo(contentB);
        if (textCompare != 0) return textCompare;
        return a.fragmentId.compareTo(b.fragmentId);
      });
    final selected = sorted.first;
    final selectedContent = _normalizeComparableText(selected.raw['content']);
    final allContained = sorted.every((candidate) {
      final content = _normalizeComparableText(candidate.raw['content']);
      return content == selectedContent || selectedContent.contains(content);
    });
    return allContained ? selected : null;
  }

  List<String> _selectOptions(
    List<_QuestionFragment> fragments,
    _QuestionFragment selectedStem,
  ) {
    final sameFile = fragments
        .where((fragment) => fragment.fileIndex == selectedStem.fileIndex)
        .where((fragment) => _readOptions(fragment.raw['options']).isNotEmpty)
        .toList();
    if (sameFile.isEmpty) {
      return _readOptions(selectedStem.raw['options']);
    }
    sameFile.sort((a, b) {
      final optionsA = _readOptions(a.raw['options']);
      final optionsB = _readOptions(b.raw['options']);
      final lengthCompare = optionsB.length.compareTo(optionsA.length);
      if (lengthCompare != 0) return lengthCompare;
      return optionsA.join('\n').compareTo(optionsB.join('\n'));
    });
    return _readOptions(sameFile.first.raw['options']);
  }

  _AnswerSelection _selectAnswer(List<_QuestionFragment> fragments) {
    final withAnswers = fragments
        .where(
          (fragment) => _hasNonEmptyString(fragment.raw['standard_answer']),
        )
        .toList();
    if (withAnswers.isEmpty) return const _AnswerSelection();

    final byComparableAnswer = <String, List<_QuestionFragment>>{};
    for (final fragment in withAnswers) {
      final key = _normalizeComparableText(fragment.raw['standard_answer']);
      byComparableAnswer
          .putIfAbsent(key, () => <_QuestionFragment>[])
          .add(fragment);
    }
    if (byComparableAnswer.length > 1) {
      return _AnswerSelection(
        hasConflict: true,
        fragments: List<_QuestionFragment>.unmodifiable(withAnswers),
      );
    }

    withAnswers.sort((a, b) {
      final roleCompare = _answerRoleRank(b.profile.role)
          .compareTo(_answerRoleRank(a.profile.role));
      if (roleCompare != 0) return roleCompare;
      final answerA = _readString(a.raw['standard_answer']);
      final answerB = _readString(b.raw['standard_answer']);
      final textCompare = answerA.compareTo(answerB);
      if (textCompare != 0) return textCompare;
      return a.fragmentId.compareTo(b.fragmentId);
    });
    return _AnswerSelection(
      fragment: withAnswers.first,
      fragments: List<_QuestionFragment>.unmodifiable(withAnswers),
    );
  }

  _QuestionFragment? _selectExplanation(List<_QuestionFragment> fragments) {
    final candidates = fragments
        .where(
          (fragment) => _hasNonEmptyString(fragment.raw['explanation']),
        )
        .toList();
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) {
      final roleCompare = _answerRoleRank(b.profile.role)
          .compareTo(_answerRoleRank(a.profile.role));
      if (roleCompare != 0) return roleCompare;
      final explanationA = _readString(a.raw['explanation']);
      final explanationB = _readString(b.raw['explanation']);
      final lengthCompare = explanationB.length.compareTo(explanationA.length);
      if (lengthCompare != 0) return lengthCompare;
      final textCompare = explanationA.compareTo(explanationB);
      if (textCompare != 0) return textCompare;
      return a.fragmentId.compareTo(b.fragmentId);
    });
    return candidates.first;
  }

  int _answerRoleRank(QuestionBatchRole role) {
    return switch (role) {
      QuestionBatchRole.answerDominant => 3,
      QuestionBatchRole.mixed => 2,
      QuestionBatchRole.stemDominant => 1,
      QuestionBatchRole.ambiguous => 0,
    };
  }

  MultiFileQuestionConflict _conflict(
    MultiFileQuestionConflictKind kind,
    int number,
    List<_QuestionFragment> fragments,
  ) {
    final fragmentIds = fragments.map((fragment) => fragment.fragmentId).toSet()
      ..removeWhere((id) => id.isEmpty);
    final sortedIds = fragmentIds.toList()..sort();
    return MultiFileQuestionConflict(
      kind: kind,
      questionNumber: number,
      fragmentIds: List<String>.unmodifiable(sortedIds),
    );
  }

  void _mergeProvenance(
    Map<String, dynamic> target,
    List<_QuestionFragment> fragments,
  ) {
    final pageIndices = <int>{};
    final blockIds = <String>{};
    final fileIndices = <int>{};
    final fragmentIds = <String>{};

    for (final fragment in fragments) {
      fileIndices.add(fragment.fileIndex);
      fragmentIds.add(fragment.fragmentId);
      final rawPages = fragment.raw['source_page_indices'];
      if (rawPages is List) {
        for (final value in rawPages) {
          final parsed = switch (value) {
            final int raw => raw,
            final num raw => raw.toInt(),
            final String raw => int.tryParse(raw.trim()),
            _ => null,
          };
          if (parsed != null) pageIndices.add(parsed);
        }
      }
      final rawBlocks = fragment.raw['source_block_ids'];
      if (rawBlocks is List) {
        for (final value in rawBlocks) {
          final blockId = _readString(value);
          if (blockId.isNotEmpty) blockIds.add(blockId);
        }
      }
    }

    target['source_page_indices'] = pageIndices.toList()..sort();
    target['source_block_ids'] = blockIds.toList()..sort();
    target['source_file_indices'] = fileIndices.toList()..sort();
    target['source_fragment_ids'] = fragmentIds.toList()..sort();
  }

  bool _hasValidStem(Map<String, dynamic> question) {
    final content = _readString(question['content']);
    if (content.isEmpty) return false;
    final normalized = content.replaceAll(RegExp(r'\s+'), '').toLowerCase();
    const placeholders = <String>{
      '无题干',
      '题干',
      '题干内容',
      '原题干',
      '同上',
      'omitted',
      'placeholder',
    };
    return !placeholders.contains(normalized);
  }

  bool _hasCompleteOptions(Map<String, dynamic> question) {
    return _readOptions(question['options']).length >= 2;
  }

  bool _hasNonEmptyString(Object? value) => _readString(value).isNotEmpty;

  List<String> _readOptions(Object? value) {
    if (value is! List) return <String>[];
    return value
        .map(_readString)
        .where((option) => option.isNotEmpty)
        .toList(growable: false);
  }

  String _readString(Object? value) => value?.toString().trim() ?? '';

  String _normalizeComparableText(Object? value) {
    return _readString(value).replaceAll(RegExp(r'\s+'), '').toLowerCase();
  }
}

class _QuestionFragment {
  const _QuestionFragment({
    required this.fileIndex,
    required this.questionIndex,
    required this.questionNumber,
    required this.raw,
    required this.profile,
  });

  final int fileIndex;
  final int questionIndex;
  final int? questionNumber;
  final Map<String, dynamic> raw;
  final QuestionBatchProfile profile;

  String get fragmentId => 'file_${fileIndex}_question_$questionIndex';

  MultiFileQuestionResidual toResidual() {
    return MultiFileQuestionResidual(
      fragmentId: fragmentId,
      fileIndex: fileIndex,
      questionIndex: questionIndex,
      questionNumber: questionNumber,
      question: Map<String, dynamic>.unmodifiable(
        Map<String, dynamic>.from(raw),
      ),
    );
  }
}

class _AnswerSelection {
  const _AnswerSelection({
    this.fragment,
    this.hasConflict = false,
    this.fragments = const <_QuestionFragment>[],
  });

  final _QuestionFragment? fragment;
  final bool hasConflict;
  final List<_QuestionFragment> fragments;
}

int _compareFragmentsBySourcePosition(
  _QuestionFragment a,
  _QuestionFragment b,
) {
  final fileCompare = a.fileIndex.compareTo(b.fileIndex);
  if (fileCompare != 0) return fileCompare;
  return a.questionIndex.compareTo(b.questionIndex);
}
