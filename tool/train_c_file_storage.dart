import 'dart:io';

import 'train_c_file_storage_stub.dart'
    if (dart.library.ui) 'train_c_file_storage_flutter.dart' as implementation;

Object createTrainCManagedFileStorage({required Directory managedRoot}) {
  return implementation.createTrainCManagedFileStorage(
    managedRoot: managedRoot,
  );
}
