/// SQLite API/runtime selection shared by Flutter and standalone Dart.
///
/// Flutter builds retain the existing sqflite plugin surface. Plain Dart
/// processes use sqflite_common_ffi without importing Flutter or dart:ui.
library;

export 'sqflite_runtime_standalone.dart'
    if (dart.library.ui) 'sqflite_runtime_flutter.dart';
