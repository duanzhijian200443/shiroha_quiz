import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;

import '../bounded_json_object.dart';
import 'link_values.dart';

Future<Uint8List> readBoundedLinkFile(File file,
    {int limit = linkStateLimit}) async {
  if (await FileSystemEntity.type(file.path, followLinks: false) !=
      FileSystemEntityType.file) {
    linkFail('invalid_state');
  }
  final handle = await file.open();
  try {
    final size = await handle.length();
    if (size < 1 || size > limit) linkFail('invalid_state');
    final bytes = await handle.read(size + 1);
    if (bytes.length != size || await handle.length() != size) {
      linkFail('invalid_state');
    }
    return bytes;
  } finally {
    await handle.close();
  }
}

/// Single writer, no SQLite, no credentials, and no automatic crash repair.
final class LinkStateStore {
  LinkStateStore._(this.directory, this._lock, this._state);
  final Directory directory;
  final RandomAccessFile _lock;
  LinkState _state;
  bool _closed = false, _writing = false, _failed = false;
  LinkState get state => _state;
  File get _file => File(p.join(directory.path, 'link-state.json'));
  File get _pending => File(p.join(directory.path, 'link-state.pending'));

  static Future<LinkStateStore> open(Directory directory,
      {String? initializeInstance}) async {
    if (!p.isAbsolute(directory.path) ||
        await FileSystemEntity.type(directory.path, followLinks: false) !=
            FileSystemEntityType.directory) {
      linkFail('invalid_state');
    }
    final lockFile = File(p.join(directory.path, 'link-owner.lock'));
    if (await FileSystemEntity.type(lockFile.path, followLinks: false) ==
        FileSystemEntityType.link) {
      linkFail('invalid_state');
    }
    final lock = await lockFile.open(mode: FileMode.append);
    var locked = false;
    try {
      await lock.lock(FileLock.exclusive);
      locked = true;
      final pending = File(p.join(directory.path, 'link-state.pending'));
      if (await pending.exists()) linkFail();
      final file = File(p.join(directory.path, 'link-state.json'));
      LinkState state;
      if (!await file.exists()) {
        if (initializeInstance == null) linkFail('invalid_state');
        state = LinkState(connectorInstanceId: linkToken(initializeInstance));
        final handle = await pending.open(mode: FileMode.writeOnly);
        try {
          await handle.writeString(jsonEncode(state.toJson()));
          await handle.flush();
        } finally {
          await handle.close();
        }
        await pending.rename(file.path);
      } else {
        state = LinkState.fromJson(boundedJsonObject(
            await readBoundedLinkFile(file),
            maxBytes: linkStateLimit));
        if (initializeInstance != null &&
            state.connectorInstanceId != initializeInstance) {
          linkFail('invalid_state');
        }
      }
      return LinkStateStore._(directory, lock, state);
    } catch (_) {
      if (locked) await lock.unlock();
      await lock.close();
      rethrow;
    }
  }

  Future<void> replace(LinkState next, {required int expectedRevision}) async {
    if (_closed || _failed || _writing) linkFail();
    _writing = true;
    try {
      // Full parse also checks in-memory callers; unknown fields cannot persist.
      next = LinkState.fromJson(Map<String, dynamic>.from(next.toJson()));
      final original = await readBoundedLinkFile(_file);
      final actual = LinkState.fromJson(
          boundedJsonObject(original, maxBytes: linkStateLimit));
      if (actual.revision != expectedRevision ||
          expectedRevision != _state.revision ||
          next.revision != expectedRevision + 1 ||
          next.connectorInstanceId != actual.connectorInstanceId ||
          jsonEncode(actual.toJson()) != jsonEncode(_state.toJson()) ||
          await _pending.exists()) {
        linkFail('stale_revision');
      }
      final bytes = utf8.encode(jsonEncode(next.toJson()));
      if (bytes.length > linkStateLimit) linkFail('invalid_state');
      final staged = await _pending.open(mode: FileMode.writeOnly);
      try {
        await staged.writeFrom(bytes);
        await staged.flush();
      } finally {
        await staged.close();
      }
      // Same-directory rename is the only publication; retain pending on error.
      await _pending.rename(_file.path);
      final confirmed = await readBoundedLinkFile(_file);
      if (base64Encode(confirmed) != base64Encode(bytes)) linkFail();
      _state = next;
    } catch (_) {
      _failed = true;
      rethrow;
    } finally {
      _writing = false;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    if (_writing) linkFail();
    _closed = true;
    await _lock.unlock();
    await _lock.close();
  }
}
