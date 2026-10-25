import 'dart:io';

// Test artifacts only. Process exit/stream/Owner assertions remain with their
// original callers. Sharing recovery never substitutes for those barriers.
Future<int> deleteSettledTestDirectory(Directory directory,
    {required Future<void> settled,
    bool? windows,
    Future<void> Function()? remove,
    Future<void> Function()? waitForRelease}) async {
  await settled;
  final delete = remove ?? () async => directory.delete(recursive: true);
  final wait = waitForRelease ??
      () => Future<void>.delayed(const Duration(milliseconds: 50));
  FileSystemException? firstSharingFailure;
  StackTrace? firstSharingStack;
  var retries = 0;
  while (true) {
    try {
      await delete();
      break;
    } on FileSystemException catch (error, stack) {
      if (!(windows ?? Platform.isWindows) || error.osError?.errorCode != 32) {
        rethrow;
      }
      firstSharingFailure ??= error;
      firstSharingStack ??= stack;
      // At most one second of sharing waits, within the existing test timeout.
      // Persistent sharing retains the FIRST error and never reports success.
      if (retries == 20) {
        Error.throwWithStackTrace(firstSharingFailure, firstSharingStack);
      }
      retries++;
      await wait();
    }
  }
  if (await FileSystemEntity.type(directory.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw StateError('Test directory cleanup incomplete');
  }
  return retries;
}
