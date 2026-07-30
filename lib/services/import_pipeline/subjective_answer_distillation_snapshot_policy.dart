abstract final class SubjectiveAnswerDistillationSnapshotPolicy {
  static const _supportedStatuses = {
    'local_extracted',
    'proof_explanation_recognized',
    'ai_applied',
    'ai_rejected',
    'ai_failed',
  };

  static const _rejectedReasons = {
    'answer_distillation_rejected',
    'answer_distillation_rejected_not_candidate',
    'answer_distillation_rejected_question_number_changed',
    'answer_distillation_rejected_basis',
    'answer_distillation_rejected_empty',
    'answer_distillation_rejected_placeholder',
    'answer_distillation_rejected_too_verbose',
  };

  static String? sanitizeStatus(Object? value) {
    final status = value?.toString().trim();
    if (status == null || !_supportedStatuses.contains(status)) return null;
    return status;
  }

  static bool isAiStatus(String value) =>
      const {'ai_applied', 'ai_rejected', 'ai_failed'}.contains(value);

  static String? sanitizeReason({
    required String? status,
    Object? value,
  }) {
    final safeStatus = sanitizeStatus(status);
    final reason = value?.toString().trim();
    if (safeStatus == null || reason == null || reason.isEmpty) return null;

    if (safeStatus == 'ai_rejected' && _rejectedReasons.contains(reason)) {
      return reason;
    }
    if (safeStatus == 'ai_failed' && reason == 'answer_distillation_failed') {
      return reason;
    }
    return null;
  }
}
