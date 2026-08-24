import 'dart:io';

import 'train_c_b0_runtime_stub.dart'
    if (dart.library.ui) 'train_c_b0_runtime_flutter.dart' as implementation;
import 'train_c_b0_runtime_api.dart';

export 'train_c_b0_runtime_api.dart';

TrainCBackupRuntimePort createTrainCBackupRuntime({
  required Object databaseHelper,
  required Object managedFileStorage,
  required Object contentAssetStore,
  required Directory restoreRoot,
  required Directory managedFilesRoot,
}) {
  return implementation.createTrainCBackupRuntime(
    databaseHelper: databaseHelper,
    managedFileStorage: managedFileStorage,
    contentAssetStore: contentAssetStore,
    restoreRoot: restoreRoot,
    managedFilesRoot: managedFilesRoot,
  );
}
