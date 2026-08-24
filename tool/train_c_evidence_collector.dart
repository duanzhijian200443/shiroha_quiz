import 'train_c_evidence_probe.dart';

/// The only source allowed to promote a schema-valid snapshot to final
/// acceptance is an isolated runtime collector implemented by the live runner.
/// It is intentionally not a JSON/file adapter.
abstract interface class TrainCTrustedEvidenceSource {
  Future<Map<String, dynamic>> readAuthoritativeSnapshot();
}

final class TrainCTrustedEvidenceCollector {
  const TrainCTrustedEvidenceCollector(this._probe);

  final TrainCEvidenceProbe _probe;

  Future<TrainCEvidenceProbeResult> collect(
    TrainCTrustedEvidenceSource source,
  ) async {
    final snapshot = await source.readAuthoritativeSnapshot();
    return _probe.inspectTrustedSnapshot(snapshot);
  }
}
