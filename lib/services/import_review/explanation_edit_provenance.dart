/// Explicit provenance for the Review explanation field.
///
/// The typed `RichContent` in a `TypedReviewSnapshot` and the legacy
/// explanation string in the same review draft are intentionally **not**
/// isomorphic: the typed form carries `InlineMathNode` / `TableNode` /
/// `ImageNode`, while the legacy form carries `$latex$`, pipe-separated table
/// text and `[图片]`. Both render the same user-visible content, and neither is
/// a round-trip representation of the other.
///
/// Because of that, "may the original typed structure still be used?" can never
/// be inferred from string similarity. It is decided only by an explicit record
/// of whether a user edited the explanation content.
enum ExplanationEditProvenance {
  /// No provenance marker exists for this review draft.
  ///
  /// This is the only safe reading of missing state: an older persisted draft
  /// may have been edited before provenance was recorded, so absence must never
  /// be upgraded to [untouched].
  legacyUnknown,

  /// The explanation content was never directly edited by the user since the
  /// typed snapshot was established.
  ///
  /// A retention toggle, a deterministic finalizer, safe HTML cleanup, OCR
  /// normalization, snapshot registration, an accepted AI repair and a policy
  /// discard all leave this state unchanged: none of them is a user edit of the
  /// explanation content.
  untouched,

  /// The user explicitly modified the explanation content.
  ///
  /// Once set, the original typed structure must never be re-inherited, even if
  /// the resulting text is character-identical to what it replaced: edit
  /// history cannot be recovered from the final string.
  manualEdited,
}

/// Stable ReviewDraft metadata key carrying an [ExplanationEditProvenance].
///
/// This is transient review state: it lives only in the persisted ReviewDraft
/// question map. It never enters the question schema, the typed snapshot
/// payload, or SQLite, so this contract requires no migration.
const String explanationEditProvenanceKey = '_explanation_edit_provenance';

/// Persisted token for [ExplanationEditProvenance.untouched].
const String explanationEditProvenanceUntouched = 'untouched';

/// Persisted token for [ExplanationEditProvenance.manualEdited].
const String explanationEditProvenanceManualEdited = 'manualEdited';

/// Decodes the persisted review-draft marker.
///
/// A missing or unrecognized token decodes to [ExplanationEditProvenance
/// .legacyUnknown]; a damaged marker never throws away a user's review draft.
/// The `legacyUnknown` state itself is never written back, so old drafts stay
/// honestly unknown instead of being silently upgraded.
ExplanationEditProvenance decodeExplanationEditProvenance(Object? value) {
  return switch (value?.toString()) {
    explanationEditProvenanceUntouched => ExplanationEditProvenance.untouched,
    explanationEditProvenanceManualEdited =>
      ExplanationEditProvenance.manualEdited,
    _ => ExplanationEditProvenance.legacyUnknown,
  };
}

/// Encodes a provenance state for persistence, or `null` when nothing may be
/// written.
///
/// [ExplanationEditProvenance.legacyUnknown] has no persisted token on purpose.
String? encodeExplanationEditProvenance(ExplanationEditProvenance provenance) {
  return switch (provenance) {
    ExplanationEditProvenance.legacyUnknown => null,
    ExplanationEditProvenance.untouched => explanationEditProvenanceUntouched,
    ExplanationEditProvenance.manualEdited =>
      explanationEditProvenanceManualEdited,
  };
}

/// Transitions one review item to [ExplanationEditProvenance.manualEdited].
///
/// This is the **only** sanctioned way to reach `manualEdited`, and it must be
/// called from the exact user text-save event for the explanation field. It
/// deliberately takes no text and performs no comparison: an edit that deletes
/// the original text and types it back is still an edit, and edit history can
/// never be recovered from the final string.
///
/// Nothing else may move a state to `manualEdited`:
/// * [ExplanationEditProvenance.untouched] must not be inferred from equality;
/// * reloads, retention toggles, deterministic finalization, safe HTML cleanup,
///   OCR normalization and snapshot registration are not user edits;
/// * an accepted AI repair stays under the existing `ReviewRepairEdit`
///   authority and does not pass through here.
///
/// `manualEdited` is sticky: once a user edited the content, later saves must
/// keep it manual even if the text later matches the original again.
ExplanationEditProvenance markExplanationManuallyEdited() {
  return ExplanationEditProvenance.manualEdited;
}
