abstract interface class TrainCBackupRuntimePort {
  Future<void> exportTo(String destinationPath);

  Future<void> prepareRestore(String packagePath);

  Future<void> commitPreparedRestore();
}
