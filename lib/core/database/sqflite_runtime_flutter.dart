/// Flutter SQLite API surface.
library;

export 'package:sqflite/sqflite.dart';

/// Standalone initialization is never used by the Flutter composition root.
void initializeStandaloneDatabaseRuntime() {
  throw UnsupportedError(
    'Standalone database initialization is unavailable in Flutter.',
  );
}
