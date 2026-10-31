/// One explicit first-party migration action, never a model capability.
abstract interface class LocalLinkHandoff {
  Future<void> run();
}
