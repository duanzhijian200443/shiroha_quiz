import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Fixed OS prerequisites only. No parent environment, configuration, credential
/// or startup selector enters the child through this map.
Map<String, String> windowsChildEnvironment() {
  if (!Platform.isWindows) throw StateError('child environment unavailable');
  // kernel32 is a Windows KnownDLL; no application-supplied DLL path is used.
  final kernel = DynamicLibrary.open('kernel32.dll');
  final heap =
      kernel.lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
          'GetProcessHeap')();
  final allocate = kernel.lookupFunction<
      Pointer<Void> Function(Pointer<Void>, Uint32, IntPtr),
      Pointer<Void> Function(Pointer<Void>, int, int)>('HeapAlloc');
  final release = kernel.lookupFunction<
      Int32 Function(Pointer<Void>, Uint32, Pointer<Void>),
      int Function(Pointer<Void>, int, Pointer<Void>)>('HeapFree');
  final systemDirectory = kernel.lookupFunction<
      Uint32 Function(Pointer<Uint16>, Uint32),
      int Function(Pointer<Uint16>, int)>('GetSystemWindowsDirectoryW');
  const capacity = 32768;
  if (heap == nullptr) throw StateError('child environment unavailable');
  final memory = allocate(heap, 8, capacity * 2); // HEAP_ZERO_MEMORY
  if (memory == nullptr) throw StateError('child environment unavailable');
  try {
    final buffer = memory.cast<Uint16>();
    final length = systemDirectory(buffer, capacity);
    if (length <= 0 || length >= capacity || buffer[length] != 0) {
      throw StateError('child environment unavailable');
    }
    final directory = String.fromCharCodes(buffer.asTypedList(length));
    if (!p.windows.isAbsolute(directory) || directory.contains('\u0000')) {
      throw StateError('child environment unavailable');
    }
    return Map.unmodifiable({
      // Retain the inert entry that avoids the SDK's empty-block error 87.
      'SHIROHA_PROCESS_ENV_PAD': '',
      // Winsock providers require the OS installation directory even when the
      // process deliberately inherits none of its parent's environment.
      'SystemRoot': directory,
    });
  } finally {
    if (release(heap, 0, memory) == 0) {
      throw StateError('child environment release unconfirmed');
    }
  }
}
