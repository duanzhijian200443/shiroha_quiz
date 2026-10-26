// Ordinary unconnected socket only. No bind, connection, TLS or protected I/O.
import 'dart:ffi';
import 'dart:io';

void main() {
  if (Platform.environment.length != 2 ||
      Platform.environment['SHIROHA_PROCESS_ENV_PAD'] != '' ||
      !Platform.environment.keys
          .any((key) => key.toLowerCase() == 'systemroot')) {
    exitCode = 80;
    return;
  }
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
  final data = allocate(heap, 8, 1024);
  if (data == nullptr) {
    exitCode = 81;
    return;
  }
  final sockets = DynamicLibrary.open('ws2_32.dll');
  final start = sockets.lookupFunction<Int32 Function(Uint16, Pointer<Void>),
      int Function(int, Pointer<Void>)>('WSAStartup');
  final create = sockets.lookupFunction<IntPtr Function(Int32, Int32, Int32),
      int Function(int, int, int)>('socket');
  final close = sockets
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('closesocket');
  final stop =
      sockets.lookupFunction<Int32 Function(), int Function()>('WSACleanup');
  try {
    if (start(0x202, data) != 0) {
      exitCode = 82;
      return;
    }
    try {
      final socket = create(2, 1, 6);
      if (socket == -1) {
        exitCode = 83;
        return;
      }
      if (close(socket) != 0) exitCode = 84;
    } finally {
      if (stop() != 0) exitCode = 85;
    }
  } finally {
    if (release(heap, 0, data) == 0) exitCode = 86;
  }
}
