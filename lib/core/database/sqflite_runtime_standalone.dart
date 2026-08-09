/// Plain-Dart SQLite API surface backed by sqflite_common_ffi.
library;

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

export 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Initializes the SQLite backend used by standalone Dart composition roots.
void initializeStandaloneDatabaseRuntime() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
}
