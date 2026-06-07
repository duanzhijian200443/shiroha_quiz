import 'question_fragment.dart';
import 'question_fusion_result.dart';

class _AnswerSelection {
  final String? answer;
  final bool hasConflict;
  const _AnswerSelection(this.answer, this.hasConflict);
}

class _FusionBucket {
  final String key;
  final List<QuestionFragment> fragments = [];

  _FusionBucket(this.key);

  void add(QuestionFragment fragment) {
    fragments.add(fragment);
  }
}

class QuestionFusionService {
  const QuestionFusionService();

  QuestionFusionResult fuse(List<QuestionFragment> fragments) {
    final numberedBuckets = <String, _FusionBucket>{};
    final contentBuckets = <String, _FusionBucket>{};
    final orphans = <QuestionFragment>[];
    final diagnostics = <String>[];

    for (final fragment in fragments) {
      if (fragment.hasQuestionNumber) {
        final key = fragment.identity.normalizedQuestionNumber;
        numberedBuckets
            .putIfAbsent(key, () => _FusionBucket(key))
            .add(fragment);
        continue;
      }

      if (fragment.kind == QuestionFragmentKind.answerOnly ||
          fragment.kind == QuestionFragmentKind.partialQuestion) {
        orphans.add(fragment);
        continue;
      }

      if (fragment.hasStem) {
        final key = fragment.identity.normalizedContent;
        if (key.length > 5) {
          contentBuckets
              .putIfAbsent(key, () => _FusionBucket(key))
              .add(fragment);
        } else {
          orphans.add(fragment);
        }
        continue;
      }

      orphans.add(fragment);
    }

    final finalQuestions = <Map<String, dynamic>>[];
    var mergedCount = 0;

    final sortedNumKeys = numberedBuckets.keys.toList()
      ..sort((a, b) {
        final numA =
            int.tryParse(RegExp(r'\d+').firstMatch(a)?.group(0) ?? '999999') ??
                999999;
        final numB =
            int.tryParse(RegExp(r'\d+').firstMatch(b)?.group(0) ?? '999999') ??
                999999;
        if (numA != numB) return numA.compareTo(numB);
        return a.compareTo(b);
      });

    for (final key in sortedNumKeys) {
      final bucket = numberedBuckets[key]!;

      final hasValidStem = bucket.fragments.any((f) =>
          f.kind == QuestionFragmentKind.fullQuestion ||
          f.kind == QuestionFragmentKind.stemOnly);

      if (!hasValidStem) {
        orphans.addAll(bucket.fragments);
        continue;
      }

      if (bucket.fragments.length > 1) {
        finalQuestions.add(_mergeBucket(bucket, diagnostics, key));
        mergedCount++;
      } else {
        finalQuestions.add(
            _withReviewMetadata(bucket.fragments.first.raw, bucket.fragments));
      }
    }

    final contentOrphans = <QuestionFragment>[];
    for (final bucket in contentBuckets.values) {
      if (bucket.fragments.length > 1) {
        finalQuestions.add(_mergeBucket(bucket, diagnostics, '内容相似'));
        mergedCount++;
      } else {
        contentOrphans.add(bucket.fragments.first);
      }
    }

    orphans.addAll(contentOrphans);
    orphans.sort((a, b) => a.originalIndex.compareTo(b.originalIndex));

    for (final orphan in orphans) {
      diagnostics.add(
        '孤立题目片段已保留: index=${orphan.originalIndex}, kind=${orphan.kind.name}',
      );
      finalQuestions.add(_withReviewMetadata(orphan.raw, [orphan]));
    }

    return QuestionFusionResult(
      questions: finalQuestions,
      diagnostics: diagnostics,
      mergedCount: mergedCount,
      orphanCount: orphans.length,
    );
  }

  Map<String, dynamic> _mergeBucket(
    _FusionBucket bucket,
    List<String> diagnostics,
    String bucketDisplayId,
  ) {
    final baseFrag = _selectBaseFragment(bucket.fragments);
    final mergedMap = Map<String, dynamic>.from(baseFrag.raw);

    final contentFrag = _selectContentFragment(bucket.fragments);
    if (contentFrag != null &&
        contentFrag.kind != QuestionFragmentKind.partialQuestion) {
      mergedMap['content'] = contentFrag.raw['content'];
    } else {
      _patchIfEmpty(mergedMap, 'content', contentFrag?.raw['content']);
    }

    final optionsFrag = _selectOptionsFragment(bucket.fragments);
    if (optionsFrag != null) {
      mergedMap['options'] = optionsFrag.raw['options'];
    }

    final answerSelection =
        _selectAnswer(bucket.fragments, diagnostics, bucketDisplayId);
    if (answerSelection.answer != null) {
      mergedMap['standard_answer'] = answerSelection.answer;
    }

    final explanationFrag = _selectExplanationFragment(bucket.fragments);
    if (explanationFrag != null) {
      if (explanationFrag.kind == QuestionFragmentKind.partialQuestion) {
        _patchIfEmpty(
            mergedMap, 'explanation', explanationFrag.raw['explanation']);
      } else {
        mergedMap['explanation'] = explanationFrag.raw['explanation'];
      }
    }

    for (final fragment in bucket.fragments) {
      if (fragment.kind != QuestionFragmentKind.partialQuestion) continue;
      _patchIfEmpty(mergedMap, 'type', fragment.raw['type']);
      _patchIfEmpty(mergedMap, 'content', fragment.raw['content']);
      _patchIfEmpty(mergedMap, 'explanation', fragment.raw['explanation']);
      if (!_hasNonEmptyList(mergedMap['options']) &&
          _hasNonEmptyList(fragment.raw['options'])) {
        mergedMap['options'] = fragment.raw['options'];
      }
    }

    final extraRiskHints =
        answerSelection.hasConflict ? ['answer_conflict'] : <String>[];
    return _withReviewMetadata(mergedMap, bucket.fragments,
        extraRiskHints: extraRiskHints);
  }

  QuestionFragment _selectBaseFragment(List<QuestionFragment> fragments) {
    final preferredKinds = [
      QuestionFragmentKind.fullQuestion,
      QuestionFragmentKind.stemOnly,
      QuestionFragmentKind.partialQuestion,
      QuestionFragmentKind.answerOnly,
      QuestionFragmentKind.orphan,
    ];

    for (final kind in preferredKinds) {
      final candidates = fragments.where((f) => f.kind == kind).toList();
      if (candidates.isEmpty) continue;
      candidates.sort((a, b) => b.contentLength.compareTo(a.contentLength));
      return candidates.first;
    }

    return fragments.first;
  }

  QuestionFragment? _selectContentFragment(List<QuestionFragment> fragments) {
    final candidates = fragments
        .where((f) =>
            f.hasStem &&
            f.kind != QuestionFragmentKind.answerOnly &&
            f.kind != QuestionFragmentKind.orphan)
        .toList();
    if (candidates.isEmpty) return null;

    candidates.sort((a, b) {
      final rankCompare = _contentRank(b).compareTo(_contentRank(a));
      if (rankCompare != 0) return rankCompare;
      return b.contentLength.compareTo(a.contentLength);
    });
    return candidates.first;
  }

  int _contentRank(QuestionFragment fragment) {
    switch (fragment.kind) {
      case QuestionFragmentKind.fullQuestion:
        return 4;
      case QuestionFragmentKind.stemOnly:
        return 3;
      case QuestionFragmentKind.partialQuestion:
        return 1;
      case QuestionFragmentKind.answerOnly:
      case QuestionFragmentKind.orphan:
        return 0;
    }
  }

  QuestionFragment? _selectOptionsFragment(List<QuestionFragment> fragments) {
    final candidates = fragments
        .where((f) =>
            f.kind != QuestionFragmentKind.answerOnly &&
            f.kind != QuestionFragmentKind.orphan &&
            _hasNonEmptyList(f.raw['options']))
        .toList();
    if (candidates.isEmpty) return null;

    candidates.sort((a, b) {
      final optionsA = a.raw['options'] as List;
      final optionsB = b.raw['options'] as List;
      return optionsB.length.compareTo(optionsA.length);
    });
    return candidates.first;
  }

  _AnswerSelection _selectAnswer(
    List<QuestionFragment> fragments,
    List<String> diagnostics,
    String bucketDisplayId,
  ) {
    QuestionFragment? bestFragment;
    String? bestAnswer;
    bool hasConflict = false;

    for (final fragment in fragments) {
      final answer = fragment.answerPatch;
      if (answer == null) continue;

      if (bestAnswer == null || bestFragment == null) {
        bestAnswer = answer;
        bestFragment = fragment;
        continue;
      }

      if (bestAnswer == answer) continue;

      if (fragment.source == QuestionFragmentSource.text &&
          bestFragment.source != QuestionFragmentSource.text) {
        diagnostics.add(
          '题号/来源 $bucketDisplayId 答案冲突，保留文本答案: $answer (覆盖: $bestAnswer)',
        );
        bestAnswer = answer;
        bestFragment = fragment;
        hasConflict = true;
        continue;
      }

      if (bestFragment.source == QuestionFragmentSource.text &&
          fragment.source != QuestionFragmentSource.text) {
        diagnostics.add(
          '题号/来源 $bucketDisplayId 答案冲突，保留文本答案: $bestAnswer (忽略: $answer)',
        );
        hasConflict = true;
        continue;
      }

      diagnostics.add(
        '题号/来源 $bucketDisplayId 同源答案冲突，保留较长答案: $bestAnswer / $answer',
      );
      if (answer.length > bestAnswer.length) {
        bestAnswer = answer;
        bestFragment = fragment;
      }
      hasConflict = true;
    }

    return _AnswerSelection(bestAnswer, hasConflict);
  }

  QuestionFragment? _selectExplanationFragment(
      List<QuestionFragment> fragments) {
    final candidates = fragments.where((f) => f.hasExplanation).toList();
    if (candidates.isEmpty) return null;

    candidates.sort((a, b) {
      final expA = a.raw['explanation'].toString().trim();
      final expB = b.raw['explanation'].toString().trim();
      final lengthCompare = expB.length.compareTo(expA.length);
      if (lengthCompare != 0) return lengthCompare;
      return _contentRank(b).compareTo(_contentRank(a));
    });
    return candidates.first;
  }

  void _patchIfEmpty(Map<String, dynamic> target, String key, dynamic value) {
    if (_hasValue(target[key]) || !_hasValue(value)) return;
    target[key] = value;
  }

  bool _hasValue(dynamic value) {
    return value != null && value.toString().trim().isNotEmpty;
  }

  bool _hasNonEmptyList(dynamic value) {
    return value is List && value.isNotEmpty;
  }

  Map<String, dynamic> _withReviewMetadata(
    Map<String, dynamic> question,
    List<QuestionFragment> fragments, {
    List<String> extraRiskHints = const [],
  }) {
    final meta = <String, dynamic>{};
    final sources = fragments.map((f) => f.source.name).toSet().toList();
    if (sources.length == 1) {
      meta['source'] = sources.first;
    } else if (sources.length > 1) {
      meta['source'] = 'fused';
    } else {
      meta['source'] = 'unknown';
    }
    meta['sources'] = sources;
    meta['fragmentKinds'] = fragments.map((f) => f.kind.name).toSet().toList();
    meta['originalIndices'] = fragments.map((f) => f.originalIndex).toList();

    final riskHints = <String>{...extraRiskHints};
    if (sources.contains('vision') && !sources.contains('text')) {
      riskHints.add('vision_only');
    }
    if (sources.contains('vision') && sources.contains('text')) {
      riskHints.add('fused_from_text_vision');
    }
    for (final f in fragments) {
      if (f.kind == QuestionFragmentKind.orphan) {
        riskHints.add('orphan_fragment');
      } else if (f.kind == QuestionFragmentKind.answerOnly) {
        riskHints.add('answer_only_fragment');
      } else if (f.kind == QuestionFragmentKind.partialQuestion) {
        riskHints.add('partial_question');
      }
    }
    meta['riskHints'] = riskHints.toList();

    final result = Map<String, dynamic>.from(question);
    result['_import_review'] = meta;
    return result;
  }
}
