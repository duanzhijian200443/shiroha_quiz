import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import '../bounded_json_object.dart';
import 'link_call_diagnostics.dart';
import 'link_verification_log.dart';

/// Separate diagnostic configuration. Never reads installation/custody/secrets.
final class LinkCaptureConfig {
  const LinkCaptureConfig(this.attemptId, this.directory,
      {this.formatVersion = 1});
  final String attemptId, directory;
  final int formatVersion;
  static Future<LinkCaptureConfig?> load({String? runtimeDirectory}) async {
    try {
      final file = File(p.join(
          runtimeDirectory ?? p.dirname(Platform.resolvedExecutable),
          'link-verification-capture.json'));
      if (!await file.exists()) return null;
      final handle = await file.open();
      late List<int> bytes;
      try {
        bytes = await handle.read(4097);
      } finally {
        await handle.close();
      }
      if (bytes.length > 4096) return null;
      final value =
          boundedJsonObject(Uint8List.fromList(bytes), maxBytes: 4096);
      if (value.length != 3 ||
          (value['formatVersion'] != 1 && value['formatVersion'] != 2) ||
          value['attemptId'] is! String ||
          value['evidenceDirectory'] is! String) {
        return null;
      }
      final id = value['attemptId'] as String,
          directory = value['evidenceDirectory'] as String;
      if (!RegExp(r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$')
              .hasMatch(id) ||
          !p.isAbsolute(directory) ||
          !p.equals(directory, p.normalize(directory)) ||
          await FileSystemEntity.type(directory, followLinks: false) !=
              FileSystemEntityType.directory) {
        return null;
      }
      return LinkCaptureConfig(id, directory,
          formatVersion: value['formatVersion'] as int);
    } catch (_) {
      return null;
    }
  }
}

final class _CaptureFileTime extends Struct {
  @Uint32()
  external int low;
  @Uint32()
  external int high;
}

// Validation-only, own-process observation. No extra native ABI or package.
String? _processStarted() {
  if (!Platform.isWindows) return null;
  final kernel = DynamicLibrary.open('kernel32.dll');
  final heap =
      kernel.lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
          'GetProcessHeap')();
  if (heap == nullptr) return null;
  final allocate = kernel.lookupFunction<
      Pointer<Void> Function(Pointer<Void>, Uint32, IntPtr),
      Pointer<Void> Function(Pointer<Void>, int, int)>('HeapAlloc');
  final release = kernel.lookupFunction<
      Int32 Function(Pointer<Void>, Uint32, Pointer<Void>),
      int Function(Pointer<Void>, int, Pointer<Void>)>('HeapFree');
  final memory = allocate(heap, 8, sizeOf<_CaptureFileTime>() * 4);
  if (memory == nullptr) return null;
  try {
    final process = kernel.lookupFunction<Pointer<Void> Function(),
        Pointer<Void> Function()>('GetCurrentProcess')();
    final getTimes = kernel.lookupFunction<
        Int32 Function(
            Pointer<Void>,
            Pointer<_CaptureFileTime>,
            Pointer<_CaptureFileTime>,
            Pointer<_CaptureFileTime>,
            Pointer<_CaptureFileTime>),
        int Function(
            Pointer<Void>,
            Pointer<_CaptureFileTime>,
            Pointer<_CaptureFileTime>,
            Pointer<_CaptureFileTime>,
            Pointer<_CaptureFileTime>)>('GetProcessTimes');
    final times = memory.cast<_CaptureFileTime>();
    if (getTimes(process, times, times + 1, times + 2, times + 3) == 0) {
      return null;
    }
    final value = (times.ref.high << 32) | times.ref.low;
    return value > 0 ? value.toString() : null;
  } finally {
    release(heap, 0, memory);
  }
}

/// v1 preserves its original allocation. v2 reserves external witnesses too.
/// Frontend writes bounded finalized records; Link buffers until close.
final class LinkCallCapture {
  LinkCallCapture(this.config,
      {required this.frontend,
      String? Function()? processStarted,
      Future<RandomAccessFile> Function(File)? openFile})
      : _readProcessStarted = processStarted ?? _processStarted,
        _openFile =
            openFile ?? ((file) => file.open(mode: FileMode.writeOnlyAppend)) {
    diagnostics = LinkCallDiagnostics(_call,
        frontend: frontend, formatVersion: config.formatVersion);
  }
  final LinkCaptureConfig config;
  final bool frontend;
  final String? Function() _readProcessStarted;
  final Future<RandomAccessFile> Function(File) _openFile;
  late final LinkCallDiagnostics diagnostics;
  static const frontendCallBytes = 960, linkCallBytes = 1152;
  static const resourceBytes = 2048, resourceCount = 7;
  static const headerBytes = 256, footerBytes = 512, collisionBytes = 128;
  static const lifecycleBytes = 256, lifecycleCount = 4;
  static const externalProcessWitnessBytes = 512,
      externalClientSummaryBytes = 4096;
  static const closureAggregateBytes = 5 * frontendCallBytes +
      5 * linkCallBytes +
      resourceCount * resourceBytes +
      headerBytes +
      2 * footerBytes +
      collisionBytes +
      lifecycleCount * lifecycleBytes +
      externalProcessWitnessBytes +
      externalClientSummaryBytes;
  static const closureAggregateRecords = 27;
  static const aggregateBytes = 8 * frontendCallBytes +
      8 * linkCallBytes +
      resourceCount * resourceBytes +
      headerBytes +
      2 * footerBytes +
      collisionBytes;
  final _buffer = <List<int>>[];
  RandomAccessFile? _file;
  Future<void> _writing = Future.value();
  int _sequence = 0, _resources = 0, _bytes = 0;
  bool _failed = false, _finished = false;
  final _lifecycle = <LinkLifecycleCheckpoint, LinkLifecycleOutcome>{};
  bool get incomplete => _failed || diagnostics.incomplete;

  /// A v2 diagnostic failure cannot retain an otherwise successful exit witness.
  /// Original nonzero exits and the historical v1 policy remain unchanged.
  int exitCodeAfterFinish(int originalExitCode, {required bool complete}) =>
      config.formatVersion == 2 && !complete && originalExitCode == 0
          ? 80
          : originalExitCode;

  String get filename =>
      frontend ? 'frontend-calls.jsonl' : 'link-verification.jsonl';

  Future<void> start() async {
    if (!frontend) return;
    await _open();
    String? started;
    if (config.formatVersion == 2) {
      try {
        started = _readProcessStarted();
        if (started == null ||
            !RegExp(r'^[1-9][0-9]{0,19}$').hasMatch(started) ||
            BigInt.parse(started) > BigInt.parse('18446744073709551615')) {
          started = null;
          diagnostics.incomplete = true;
        }
      } catch (_) {
        diagnostics.incomplete = true;
      }
    }
    _append(
        jsonEncode({
          'v': config.formatVersion,
          'e': 'capture-start',
          'p': 'f',
          's': ++_sequence,
          'attemptId': config.attemptId,
          'pid': pid,
          if (config.formatVersion == 2) 'processStarted': started,
        }),
        headerBytes);
  }

  Future<void> _open() async {
    try {
      final file = File(p.join(config.directory, filename));
      await file.create(exclusive: true);
      _file = await _openFile(file);
    } catch (_) {
      _failed = true;
      try {
        final collision =
            File(p.join(config.directory, 'capture-collision.json'));
        // One fixed marker, never a per-spawn output. No original is replaced.
        await collision.create(exclusive: true);
        final bytes = utf8.encode('${jsonEncode({
              'v': config.formatVersion,
              'e': 'capture-collision',
              'attemptId': config.attemptId
            })}\n');
        if (bytes.length <= collisionBytes) {
          await collision.writeAsBytes(bytes, flush: true);
        }
      } catch (_) {
        /* Absence or existing conflict cannot establish completeness. */
      }
    }
  }

  void _append(String value, int limit) {
    if (_finished || _failed) {
      _failed = true;
      return;
    }
    try {
      final bytes = utf8.encode('$value\n');
      if (bytes.length > limit) {
        _failed = true;
        return;
      }
      _bytes += bytes.length;
      if (frontend) {
        _writing = _writing.then((_) async {
          if (_file == null) {
            _failed = true;
            return;
          }
          await _file!.writeFrom(bytes);
          await _file!.flush();
        }).catchError((Object _) {
          _failed = true;
        });
      } else {
        _buffer.add(bytes);
      }
    } catch (_) {
      _failed = true;
    }
  }

  void _call(LinkCallTrace trace) {
    try {
      _append(trace.encode(++_sequence),
          frontend ? frontendCallBytes : linkCallBytes);
    } catch (_) {
      _failed = true;
    }
  }

  void resource(LinkVerificationObservation value) {
    if (frontend || ++_resources > resourceCount) {
      _failed = true;
      return;
    }
    try {
      _append(value.encode(++_sequence), resourceBytes);
    } catch (_) {
      _failed = true;
    }
  }

  void lifecycle(
      LinkLifecycleCheckpoint checkpoint, LinkLifecycleOutcome outcome) {
    if (config.formatVersion != 2) return;
    if (!frontend) {
      diagnostics.incomplete = true;
      return;
    }
    final previous = _lifecycle[checkpoint];
    if (previous != null) {
      if (previous != outcome) diagnostics.incomplete = true;
      return;
    }
    _lifecycle[checkpoint] = outcome;
    if (outcome == LinkLifecycleOutcome.failed) diagnostics.incomplete = true;
    try {
      _append(
          jsonEncode({
            'v': 2,
            'e': 'lifecycle',
            'p': 'f',
            's': ++_sequence,
            'k': checkpoint.index,
            'o': outcome.index
          }),
          lifecycleBytes);
    } catch (_) {
      diagnostics.incomplete = true;
    }
  }

  Future<bool> finish({required bool originalClosed}) async {
    if (_finished) {
      _failed = true;
      return false;
    }
    if (frontend && config.formatVersion == 2) {
      lifecycle(LinkLifecycleCheckpoint.captureFinishEnter,
          LinkLifecycleOutcome.observed);
      if (_lifecycle.length != 4 ||
          _lifecycle[LinkLifecycleCheckpoint.portCloseSettled] !=
              LinkLifecycleOutcome.completed) {
        diagnostics.incomplete = true;
      }
    }
    diagnostics.close();
    await _writing;
    if (!frontend) {
      await _open();
      try {
        if (_file != null) {
          for (final bytes in _buffer) {
            await _file!.writeFrom(bytes);
          }
        }
      } catch (_) {
        _failed = true;
      }
    }
    final complete = originalClosed && !incomplete;
    try {
      final footer = utf8.encode('${jsonEncode({
            'v': config.formatVersion,
            'e': 'capture-finished',
            'p': frontend ? 'f' : 'l',
            's': ++_sequence,
            'attemptId': config.attemptId,
            'records': _sequence - 1,
            'calls': diagnostics.finalized,
            'observed': diagnostics.observed,
            'unassociated': diagnostics.unassociated,
            'resources': _resources,
            if (config.formatVersion == 2) 'lifecycle': _lifecycle.length,
            'complete': complete,
            'originalClosed': originalClosed,
            'priorBytes': _bytes
          })}\n');
      if (footer.length > footerBytes || _file == null) {
        _failed = true;
      } else {
        await _file!.writeFrom(footer);
        await _file!.flush();
      }
    } catch (_) {
      _failed = true;
    } finally {
      _finished = true;
      try {
        await _file?.close();
      } catch (_) {
        _failed = true;
      }
    }
    return complete && !_failed;
  }
}
