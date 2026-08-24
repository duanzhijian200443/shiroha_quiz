import 'dart:io';

import 'package:shiroha_quiz/services/file_library/managed_file_storage_adapter.dart';

Object createTrainCManagedFileStorage({required Directory managedRoot}) {
  return ManagedFileStorageAdapter(managedRoot: managedRoot);
}
