import 'dart:ffi';
import 'dart:io';

typedef _LocalAllocNative = Pointer<Void> Function(Uint32, IntPtr);
typedef _LocalAllocDart = Pointer<Void> Function(int, int);
typedef _LocalFreeNative = Pointer<Void> Function(Pointer<Void>);
typedef _LocalFreeDart = Pointer<Void> Function(Pointer<Void>);
typedef _GetFileAttributesNative = Uint32 Function(Pointer<Uint16>);
typedef _GetFileAttributesDart = int Function(Pointer<Uint16>);

/// Checks FILE_ATTRIBUTE_REPARSE_POINT without following a Windows path.
/// Failure is unknown, never a negative reparse result.
abstract final class WindowsReparsePointProbe {
  static const int _reparsePoint = 0x400;
  static const int _invalidAttributes = 0xffffffff;

  static final DynamicLibrary _kernel = DynamicLibrary.open('kernel32.dll');
  static final _LocalAllocDart _localAlloc =
      _kernel.lookupFunction<_LocalAllocNative, _LocalAllocDart>('LocalAlloc');
  static final _LocalFreeDart _localFree =
      _kernel.lookupFunction<_LocalFreeNative, _LocalFreeDart>('LocalFree');
  static final _GetFileAttributesDart _getFileAttributes =
      _kernel.lookupFunction<_GetFileAttributesNative, _GetFileAttributesDart>(
    'GetFileAttributesW',
  );

  static bool isReparsePoint(String path) {
    if (!Platform.isWindows) return false;
    final codeUnits = path.codeUnits;
    final allocation = _localAlloc(0, (codeUnits.length + 1) * 2);
    if (allocation.address == 0) {
      throw const WindowsReparsePointProbeException();
    }
    try {
      final units = allocation.cast<Uint16>().asTypedList(codeUnits.length + 1);
      units.setRange(0, codeUnits.length, codeUnits);
      units[codeUnits.length] = 0;
      final attributes = _getFileAttributes(allocation.cast<Uint16>());
      if (attributes == _invalidAttributes) {
        throw const WindowsReparsePointProbeException();
      }
      return (attributes & _reparsePoint) != 0;
    } finally {
      _localFree(allocation);
    }
  }
}

final class WindowsReparsePointProbeException implements Exception {
  const WindowsReparsePointProbeException();

  @override
  String toString() => 'WindowsReparsePointProbeException';
}
