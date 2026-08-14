import '../../domain/content/content_node.dart';
import '../../domain/content/rich_content.dart';
import '../../domain/question/question_draft_v2.dart';
import '../../domain/source/source_ref.dart';
import '../../domain/supplemental_answers/answer_candidate.dart';
import '../../domain/supplemental_answers/answer_match_record.dart';
import '../../domain/supplemental_answers/supplemental_answer_fragment.dart';
import '../../domain/supplemental_answers/target_coverage.dart';
import 'target_question_snapshot_service.dart';

final _subMarkerPattern = RegExp(r'[（(]\s*(\d{1,4})\s*[)）]');

/// Immutable artifact context bound to every candidate produced by one
/// matching session.
final class SupplementalArtifactContext {
  const SupplementalArtifactContext({
    required this.supplementalFileId,
    required this.artifactId,
    required this.artifactRevision,
  });

  final String supplementalFileId;
  final String artifactId;
  final int artifactRevision;
}

/// Result of one deterministic matching pass: per-fragment match records
/// plus per-target coverage.
final class SupplementalMatchResult {
  const SupplementalMatchResult({
    required this.records,
    required this.coverage,
  });

  final List<AnswerMatchRecord> records;
  final List<TargetCoverage> coverage;
}

/// Deterministic supplemental-answer matcher.
///
/// Freezes the canonical P6 matching contract: primary identity proofs,
/// hard type compatibility, explicit ambiguity, multi-fragment semantics,
/// and fill/noOp/conflict classification. Never auto-selects by score,
/// never writes, and never invokes OCR/AI.
final class SupplementalAnswerMatcher {
  const SupplementalAnswerMatcher();

  SupplementalMatchResult match({
    required List<SupplementalAnswerFragment> fragments,
    required TargetQuestionSnapshot snapshot,
    required SupplementalArtifactContext artifact,
  }) {
    final targets = snapshot.targets;
    final byNumber = <String, List<AnswerTargetReference>>{};
    for (final target in targets) {
      final number = target.draft.questionNumber;
      if (number == null) continue;
      byNumber
          .putIfAbsent(number.toString(), () => <AnswerTargetReference>[])
          .add(target);
    }

    final resolved = <_ResolvedFragment>[
      for (final fragment in fragments)
        ..._resolveFragment(fragment, targets, byNumber, artifact),
    ];
    final merged = _mergeDuplicateLocators(resolved, artifact);
    final composed = _composeSubquestions(merged, byNumber, artifact);
    final records = <AnswerMatchRecord>[
      for (final item in composed) item.record,
    ];

    final matchedTargetIds = <String>{
      for (final item in composed)
        if (item.record.candidate case final candidate?)
          candidate.targetStorageId,
    };
    final coverage = <TargetCoverage>[
      for (final target in targets)
        TargetCoverage(
          storageId: target.storageId,
          bankName: target.bankName,
          status: matchedTargetIds.contains(target.storageId)
              ? TargetCoverageStatus.covered
              : TargetCoverageStatus.uncovered,
        ),
      for (final report in snapshot.reports)
        if (report.code == TargetScopeReportCode.legacyIneligible)
          TargetCoverage(
            storageId: report.storageId,
            bankName: report.bankName ?? '',
            status: TargetCoverageStatus.ineligible,
          ),
    ];

    return SupplementalMatchResult(
      records: List<AnswerMatchRecord>.unmodifiable(records),
      coverage: List<TargetCoverage>.unmodifiable(coverage),
    );
  }

  List<_ResolvedFragment> _resolveFragment(
    SupplementalAnswerFragment fragment,
    List<AnswerTargetReference> targets,
    Map<String, List<AnswerTargetReference>> byNumber,
    SupplementalArtifactContext artifact,
  ) {
    final mainNumber = fragment.normalizedMainNumber;
    if (mainNumber == null) {
      return <_ResolvedFragment>[
        _resolveNumberless(fragment, targets, artifact),
      ];
    }

    final candidates = byNumber[mainNumber] ?? const <AnswerTargetReference>[];
    if (candidates.isEmpty) {
      return <_ResolvedFragment>[
        _ResolvedFragment(
          fragment: fragment,
          disposition: AnswerMatchDisposition.unmatched,
          certainty: MatchCertainty.none,
          evidence: const <MatchEvidenceCode>[
            MatchEvidenceCode.missingPrimaryProof,
          ],
        ),
      ];
    }
    if (candidates.length > 1) {
      final subquestion = fragment.normalizedSubquestion;
      if (subquestion != null) {
        final bySub = candidates.where(
          (target) => _expectedSubquestionNumbers(target.draft.stem)
              .contains(subquestion),
        );
        if (bySub.length == 1) {
          return <_ResolvedFragment>[
            _resolveUniqueTarget(
              fragment,
              bySub.single,
              artifact,
              const <MatchEvidenceCode>[
                MatchEvidenceCode.uniqueMainNumber,
                MatchEvidenceCode.mainNumberAndSubquestion,
              ],
            ),
          ];
        }
      }
      return <_ResolvedFragment>[
        _ResolvedFragment(
          fragment: fragment,
          disposition: AnswerMatchDisposition.ambiguous,
          certainty: MatchCertainty.ambiguous,
          evidence: const <MatchEvidenceCode>[
            MatchEvidenceCode.duplicateLocator,
            MatchEvidenceCode.multipleTargets,
          ],
          alternatives: List<AnswerTargetReference>.unmodifiable(candidates),
        ),
      ];
    }

    final target = candidates.single;
    final subquestion = fragment.normalizedSubquestion;
    if (subquestion != null) {
      final expected = _expectedSubquestionNumbers(target.draft.stem);
      if (expected.isEmpty || !expected.contains(subquestion)) {
        return <_ResolvedFragment>[
          _ResolvedFragment(
            fragment: fragment,
            disposition: AnswerMatchDisposition.ambiguous,
            certainty: MatchCertainty.ambiguous,
            evidence: const <MatchEvidenceCode>[
              MatchEvidenceCode.uniqueMainNumber,
              MatchEvidenceCode.subquestionSetMismatch,
            ],
            alternatives: <AnswerTargetReference>[target],
          ),
        ];
      }
    }
    final evidence = <MatchEvidenceCode>[
      MatchEvidenceCode.uniqueMainNumber,
      if (subquestion != null) MatchEvidenceCode.mainNumberAndSubquestion,
    ];
    return <_ResolvedFragment>[
      _resolveUniqueTarget(fragment, target, artifact, evidence),
    ];
  }

  _ResolvedFragment _resolveNumberless(
    SupplementalAnswerFragment fragment,
    List<AnswerTargetReference> targets,
    SupplementalArtifactContext artifact,
  ) {
    final stemContext = fragment.stemContext;
    if (stemContext == null) {
      return _ResolvedFragment(
        fragment: fragment,
        disposition: AnswerMatchDisposition.unmatched,
        certainty: MatchCertainty.none,
        evidence: const <MatchEvidenceCode>[
          MatchEvidenceCode.noLocator,
        ],
      );
    }
    final fingerprint = _stemFingerprint(stemContext);
    final matches = targets
        .where((target) => _stemFingerprint(target.draft.stem) == fingerprint)
        .toList(growable: false);
    if (matches.length == 1) {
      return _resolveUniqueTarget(
        fragment,
        matches.single,
        artifact,
        const <MatchEvidenceCode>[
          MatchEvidenceCode.uniqueStemFingerprint,
        ],
      );
    }
    return _ResolvedFragment(
      fragment: fragment,
      disposition: AnswerMatchDisposition.ambiguous,
      certainty: MatchCertainty.ambiguous,
      evidence: <MatchEvidenceCode>[
        if (matches.isEmpty)
          MatchEvidenceCode.missingPrimaryProof
        else
          MatchEvidenceCode.multipleTargets,
      ],
      alternatives: List<AnswerTargetReference>.unmodifiable(matches),
    );
  }

  _ResolvedFragment _resolveUniqueTarget(
    SupplementalAnswerFragment fragment,
    AnswerTargetReference target,
    SupplementalArtifactContext artifact,
    List<MatchEvidenceCode> identityEvidence,
  ) {
    final evidence = <MatchEvidenceCode>[
      ...identityEvidence,
      MatchEvidenceCode.typeCompatible,
      if (fragment.headingContext.isNotEmpty)
        MatchEvidenceCode.headingCorroboration,
    ];
    final converted = _convertAnswer(fragment, target);
    if (converted is _ConversionInvalid) {
      return _ResolvedFragment(
        fragment: fragment,
        disposition: AnswerMatchDisposition.invalid,
        certainty: MatchCertainty.none,
        evidence: <MatchEvidenceCode>[
          ...evidence,
          converted.evidence,
        ],
      );
    }
    final answer = (converted as _ConversionAnswer).answer;
    final current = target.draft.answer;
    final writeIntent = current == null
        ? CandidateWriteIntent.fill
        : (answer == current
            ? CandidateWriteIntent.noOp
            : CandidateWriteIntent.replace);
    final candidate = AnswerCandidate(
      candidateId: 'cand_${fragment.fragmentId}_${target.storageId}',
      targetStorageId: target.storageId,
      targetBankName: target.bankName,
      expectedDraft: target.draft,
      answer: answer,
      reviewOnlyExplanation: fragment.explanationContent,
      writeIntent: writeIntent,
      origin: SupplementalAnswerOrigin(
        supplementalFileId: artifact.supplementalFileId,
        artifactId: artifact.artifactId,
        artifactRevision: artifact.artifactRevision,
        supplementalSourceRefs: fragment.sourceRefs,
        matchEvidence: evidence,
      ),
    );
    return _ResolvedFragment(
      fragment: fragment,
      disposition: writeIntent == CandidateWriteIntent.replace
          ? AnswerMatchDisposition.conflict
          : AnswerMatchDisposition.matched,
      certainty: MatchCertainty.deterministic,
      evidence: List<MatchEvidenceCode>.unmodifiable(evidence),
      candidate: candidate,
    );
  }

  _ConversionResult _convertAnswer(
    SupplementalAnswerFragment fragment,
    AnswerTargetReference target,
  ) {
    if (fragment.answerContent.nodes.any((node) => node is RawFallbackNode)) {
      return const _ConversionInvalid(MatchEvidenceCode.unsupportedContent);
    }
    if (target.draft.kind == QuestionKind.singleChoice) {
      final label = _plainText(fragment.answerContent)?.trim() ?? '';
      if (label.isEmpty) {
        return const _ConversionInvalid(MatchEvidenceCode.noLocator);
      }
      final matches = target.draft.options
          .where((option) => option.label.trim() == label)
          .toList(growable: false);
      if (matches.length != 1) {
        return const _ConversionInvalid(
          MatchEvidenceCode.ambiguousChoiceLabel,
        );
      }
      return _ConversionAnswer(
        ChoiceAnswer(optionIds: <String>[matches.single.optionId]),
      );
    }
    return _ConversionAnswer(ContentAnswer(content: fragment.answerContent));
  }
}

sealed class _ConversionResult {
  const _ConversionResult();
}

final class _ConversionAnswer extends _ConversionResult {
  const _ConversionAnswer(this.answer);

  final QuestionAnswer answer;
}

final class _ConversionInvalid extends _ConversionResult {
  const _ConversionInvalid(this.evidence);

  final MatchEvidenceCode evidence;
}

/// One resolved fragment before duplicate-locator merging.
final class _ResolvedFragment {
  const _ResolvedFragment({
    required this.fragment,
    required this.disposition,
    required this.certainty,
    required this.evidence,
    this.candidate,
    this.alternatives = const <AnswerTargetReference>[],
  });

  final SupplementalAnswerFragment fragment;
  final AnswerMatchDisposition disposition;
  final MatchCertainty certainty;
  final List<MatchEvidenceCode> evidence;
  final AnswerCandidate? candidate;
  final List<AnswerTargetReference> alternatives;
}

/// Merges duplicate-locator fragments: structurally equal answers merge
/// provenance into one candidate; conflicting answers become invalid.
List<_MergedItem> _mergeDuplicateLocators(
  List<_ResolvedFragment> resolved,
  SupplementalArtifactContext artifact,
) {
  final byLocator = <(String, String?), List<_ResolvedFragment>>{};
  for (final item in resolved) {
    final key = (
      item.fragment.normalizedMainNumber ?? '',
      item.fragment.normalizedSubquestion,
    );
    byLocator.putIfAbsent(key, () => <_ResolvedFragment>[]).add(item);
  }

  final merged = <_MergedItem>[];
  for (final items in byLocator.values) {
    final candidates = items
        .map((item) => item.candidate)
        .whereType<AnswerCandidate>()
        .toList();
    if (items.length == 1 || candidates.isEmpty) {
      merged.addAll(items.map(_MergedItem.single));
      continue;
    }
    final firstAnswer = candidates.first.answer;
    final allEqual =
        candidates.every((candidate) => candidate.answer == firstAnswer);
    if (!allEqual) {
      merged.add(
        _MergedItem.single(
          _ResolvedFragment(
            fragment: items.first.fragment,
            disposition: AnswerMatchDisposition.invalid,
            certainty: MatchCertainty.none,
            evidence: const <MatchEvidenceCode>[
              MatchEvidenceCode.sourceConflict,
            ],
          ),
        ),
      );
      continue;
    }
    final first = candidates.first;
    final sourceRefs = <SourceRef>[
      for (final item in items) ..._supplementalSourceRefs(item.candidate!),
    ];
    final candidate = AnswerCandidate(
      candidateId: first.candidateId,
      targetStorageId: first.targetStorageId,
      targetBankName: first.targetBankName,
      expectedDraft: first.expectedDraft,
      answer: first.answer,
      reviewOnlyExplanation: first.reviewOnlyExplanation,
      writeIntent: first.writeIntent,
      origin: SupplementalAnswerOrigin(
        supplementalFileId: artifact.supplementalFileId,
        artifactId: artifact.artifactId,
        artifactRevision: artifact.artifactRevision,
        supplementalSourceRefs: sourceRefs,
        matchEvidence: _supplementalEvidence(first),
      ),
    );
    merged.add(
      _MergedItem.single(
        _ResolvedFragment(
          fragment: items.first.fragment,
          disposition: first.writeIntent == CandidateWriteIntent.replace
              ? AnswerMatchDisposition.conflict
              : AnswerMatchDisposition.matched,
          certainty: MatchCertainty.deterministic,
          evidence: _supplementalEvidence(first),
          candidate: candidate,
        ),
      ),
    );
  }
  return merged;
}

/// Composes subquestion fragments of one main number into one
/// `ContentAnswer` when the expected transient sub set is uniquely and
/// completely covered; otherwise keeps them ambiguous.
List<_MergedItem> _composeSubquestions(
  List<_MergedItem> merged,
  Map<String, List<AnswerTargetReference>> byNumber,
  SupplementalArtifactContext artifact,
) {
  final items = merged.toList(growable: false);
  final byMain = <String, List<_MergedItem>>{};
  final indexByItem = <_MergedItem, int>{
    for (var index = 0; index < items.length; index++) items[index]: index,
  };
  for (final item in items) {
    final main = item.resolved.fragment.normalizedMainNumber;
    final sub = item.resolved.fragment.normalizedSubquestion;
    if (main == null || sub == null) continue;
    byMain.putIfAbsent(main, () => <_MergedItem>[]).add(item);
  }

  final result = <_MergedItem>[];
  final consumed = <int>{};
  for (final entry in byMain.entries) {
    final group = entry.value;
    final targets = byNumber[entry.key] ?? const <AnswerTargetReference>[];
    // A duplicate-number group that was already disambiguated by a unique
    // sub-proof is final; only a single unique-number target participates
    // in subquestion composition.
    if (targets.length != 1) continue;
    final target = targets.single;
    final expected = _expectedSubquestionNumbers(target.draft.stem);
    if (group.length == 1) {
      final item = group.single;
      final candidate = item.resolved.candidate;
      if (candidate == null) continue;
      if (expected.length > 1) {
        result.add(
          _MergedItem.single(
            _ResolvedFragment(
              fragment: item.resolved.fragment,
              disposition: AnswerMatchDisposition.ambiguous,
              certainty: MatchCertainty.ambiguous,
              evidence: const <MatchEvidenceCode>[
                MatchEvidenceCode.subquestionSetMismatch,
              ],
            ),
          ),
        );
        consumed.add(indexByItem[item]!);
      }
      continue;
    }
    if (target.draft.kind == QuestionKind.singleChoice) {
      for (final item in group) {
        result.add(
          _MergedItem.single(
            _ResolvedFragment(
              fragment: item.resolved.fragment,
              disposition: AnswerMatchDisposition.ambiguous,
              certainty: MatchCertainty.ambiguous,
              evidence: const <MatchEvidenceCode>[
                MatchEvidenceCode.typeIncompatible,
              ],
            ),
          ),
        );
        consumed.add(indexByItem[item]!);
      }
      continue;
    }
    final actual = group
        .map((item) => item.resolved.fragment.normalizedSubquestion!)
        .toSet();
    if (!_setEquals(expected, actual)) {
      for (final item in group) {
        result.add(
          _MergedItem.single(
            _ResolvedFragment(
              fragment: item.resolved.fragment,
              disposition: AnswerMatchDisposition.ambiguous,
              certainty: MatchCertainty.ambiguous,
              evidence: const <MatchEvidenceCode>[
                MatchEvidenceCode.subquestionSetMismatch,
              ],
            ),
          ),
        );
        consumed.add(indexByItem[item]!);
      }
      continue;
    }
    final ordered = group.toList(growable: false)
      ..sort(
        (left, right) => left.resolved.fragment.normalizedSubquestion!
            .compareTo(right.resolved.fragment.normalizedSubquestion!),
      );
    final nodes = <ContentNode>[
      for (final item in ordered)
        ...(item.resolved.candidate!.answer as ContentAnswer).content.nodes,
    ];
    final sourceRefs = <SourceRef>[
      for (final item in ordered)
        ..._supplementalSourceRefs(item.resolved.candidate!),
    ];
    final composedAnswer = ContentAnswer(content: RichContent(nodes: nodes));
    final currentAnswer = target.draft.answer;
    final writeIntent = currentAnswer == null
        ? CandidateWriteIntent.fill
        : (composedAnswer == currentAnswer
            ? CandidateWriteIntent.noOp
            : CandidateWriteIntent.replace);
    final evidence = const <MatchEvidenceCode>[
      MatchEvidenceCode.uniqueMainNumber,
      MatchEvidenceCode.mainNumberAndSubquestion,
    ];
    final candidate = AnswerCandidate(
      candidateId: 'cand_${entry.key}_${target.storageId}',
      targetStorageId: target.storageId,
      targetBankName: target.bankName,
      expectedDraft: target.draft,
      answer: composedAnswer,
      reviewOnlyExplanation: null,
      writeIntent: writeIntent,
      origin: SupplementalAnswerOrigin(
        supplementalFileId: artifact.supplementalFileId,
        artifactId: artifact.artifactId,
        artifactRevision: artifact.artifactRevision,
        supplementalSourceRefs: sourceRefs,
        matchEvidence: evidence,
      ),
    );
    result.add(
      _MergedItem.single(
        _ResolvedFragment(
          fragment: ordered.first.resolved.fragment,
          disposition: writeIntent == CandidateWriteIntent.replace
              ? AnswerMatchDisposition.conflict
              : AnswerMatchDisposition.matched,
          certainty: MatchCertainty.deterministic,
          evidence: _supplementalEvidence(candidate),
          candidate: candidate,
        ),
      ),
    );
    for (final item in group) {
      consumed.add(indexByItem[item]!);
    }
  }
  for (var index = 0; index < items.length; index++) {
    if (!consumed.contains(index)) result.add(items[index]);
  }
  return result;
}

final class _MergedItem {
  const _MergedItem({required this.resolved});

  factory _MergedItem.single(_ResolvedFragment resolved) {
    return _MergedItem(resolved: resolved);
  }

  final _ResolvedFragment resolved;

  AnswerMatchRecord get record => AnswerMatchRecord(
        fragmentId: resolved.fragment.fragmentId,
        disposition: resolved.disposition,
        certainty: resolved.certainty,
        evidence: resolved.evidence,
        candidate: resolved.candidate,
        alternatives: resolved.alternatives,
      );
}

/// Ordered supplemental source refs of a matcher-produced candidate.
///
/// The matcher only ever builds Supplemental origins; the exhaustive switch
/// fails closed with a programming-error `StateError` if a foreign producer
/// origin ever reaches merge/composition, instead of casting blindly.
List<SourceRef> _supplementalSourceRefs(AnswerCandidate candidate) {
  return switch (candidate.origin) {
    SupplementalAnswerOrigin(:final supplementalSourceRefs) =>
      supplementalSourceRefs,
    AiAnswerOrigin() => throw StateError(
        'Matcher candidates must carry a SupplementalAnswerOrigin.',
      ),
  };
}

/// Typed match evidence of a matcher-produced candidate (see
/// [_supplementalSourceRefs] for the fail-closed contract).
List<MatchEvidenceCode> _supplementalEvidence(AnswerCandidate candidate) {
  return switch (candidate.origin) {
    SupplementalAnswerOrigin(:final matchEvidence) => matchEvidence,
    AiAnswerOrigin() => throw StateError(
        'Matcher candidates must carry a SupplementalAnswerOrigin.',
      ),
  };
}

Set<String> _expectedSubquestionNumbers(RichContent stem) {
  final result = <String>{};
  for (final node in stem.nodes) {
    if (node is! TextNode) continue;
    for (final match in _subMarkerPattern.allMatches(node.text)) {
      result.add(match.group(1)!);
    }
  }
  return result;
}

String _stemFingerprint(RichContent content) {
  return content.nodes.map(_nodeFingerprint).join('|');
}

String _nodeFingerprint(ContentNode node) {
  return switch (node) {
    TextNode(:final text) => 'text:$text',
    InlineMathNode(:final latex) => 'inline:$latex',
    BlockMathNode(:final latex) => 'block:$latex',
    RawFallbackNode(:final rawJson) => 'raw:${rawJson.keys.toList()..sort()}',
  };
}

String? _plainText(RichContent content) {
  if (content.nodes.isEmpty) return null;
  final buffer = StringBuffer();
  for (final node in content.nodes) {
    if (node is TextNode) buffer.write(node.text);
  }
  final value = buffer.toString();
  return value.isEmpty ? null : value;
}

bool _setEquals(Set<String> left, Set<String> right) {
  if (left.length != right.length) return false;
  return left.containsAll(right);
}
