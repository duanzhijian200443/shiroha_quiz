/// Flutter SQLite API surface.
library;

import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

export 'package:sqflite/sqflite.dart';

/// Installs the desktop FFI SQLite runtime for Flutter composition roots that
/// do not run through `lib/main.dart`, such as the guarded TRAIN C Windows
/// acceptance child.
///
/// The production Windows/Linux app performs the same FFI bootstrap in
/// `main.dart`. Mobile Flutter compositions remain unsupported here so this
/// helper cannot silently change their database backend.
void initializeStandaloneDatabaseRuntime() {
  if (!Platform.isWindows && !Platform.isLinux) {
    throw UnsupportedError(
      'Standalone database initialization is unavailable on this Flutter platform.',
    );
  }
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
}
