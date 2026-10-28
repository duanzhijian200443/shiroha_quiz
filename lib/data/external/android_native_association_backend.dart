import 'dart:async';
import 'package:flutter/services.dart';

import '../../application/external/external_credential_association.dart';
import 'android_association_store.dart';

/// Local platform calls only. No network DTO can implement this trusted seam.
abstract interface class AndroidNativeCalls {
  Future<Object?> invoke(String method, [Map<String, Object?>? arguments]);
}

final class AndroidDeviceMethodChannel implements AndroidNativeCalls {
  AndroidDeviceMethodChannel() {
    _channel.setMethodCallHandler((call) async {
      if (call.arguments is Map) {
        _events.add(
            (call.method, Map<String, Object?>.from(call.arguments as Map)));
      }
    });
  }
  static const _channel = MethodChannel('shiroha/android_device_foundation');
  final _events =
      StreamController<(String, Map<String, Object?>)>.broadcast(sync: true);
  Stream<(String, Map<String, Object?>)> get events => _events.stream;
  Future<void> close() async {
    _channel.setMethodCallHandler(null);
    await _events.close();
  }

  @override
  Future<Object?> invoke(String method, [Map<String, Object?>? arguments]) =>
      _channel.invokeMethod<Object?>(method, arguments);
}

/// Dormant adapter for the Native fixed-object lease. No calls at construction.
/// Native rejects acquisition in the source-only foundation delivery.
final class AndroidNativeAssociationBackend
    implements AndroidAssociationBackend {
  AndroidNativeAssociationBackend(this.calls);
  final AndroidNativeCalls calls;
  bool _current = true;
  bool _occupied = false;
  @override
  bool get isCurrent => _current;

  Future<Object?> _call(String method,
      [Map<String, Object?>? arguments]) async {
    if (!_current) {
      credentialFail(ExternalCredentialFailure.temporarilyUnavailable);
    }
    try {
      return await calls.invoke(method, arguments);
    } on PlatformException catch (e) {
      _current = false;
      credentialFail(switch (e.code) {
        'credential_store_corrupt' => ExternalCredentialFailure.dataCorrupt,
        'commit_unknown' => ExternalCredentialFailure.commitUnknown,
        'stale_revision' => ExternalCredentialFailure.staleRevision,
        'resource_limit' => ExternalCredentialFailure.resourceLimit,
        _ => ExternalCredentialFailure.temporarilyUnavailable,
      });
    } catch (_) {
      _current = false;
      credentialFail(ExternalCredentialFailure.temporarilyUnavailable);
    }
  }

  @override
  Future<AndroidAssociationLease> begin() async {
    if (_occupied) credentialFail(ExternalCredentialFailure.resourceLimit);
    _occupied = true;
    try {
      final reply = await _call('associationBegin');
      if (reply is! Map ||
          reply.length != 2 ||
          reply['lease'] is! int ||
          (reply['lease'] as int) <= 0 ||
          (reply['plaintext'] != null && reply['plaintext'] is! Uint8List)) {
        _current = false;
        credentialFail(ExternalCredentialFailure.dataCorrupt);
      }
      final bytes = reply['plaintext'] as Uint8List?;
      if (bytes != null && bytes.length > AndroidAssociationStore.maxBytes) {
        _current = false;
        credentialFail(ExternalCredentialFailure.dataCorrupt);
      }
      return _NativeLease(this, reply['lease'] as int, bytes);
    } catch (_) {
      _occupied = false;
      rethrow;
    }
  }

  /// Invalidates the in-memory owner; cannot be reopened after a platform loss.
  void invalidate() {
    _current = false;
  }
}

final class _NativeLease implements AndroidAssociationLease {
  _NativeLease(this.owner, this.token, Uint8List? bytes)
      : _bytes = bytes == null ? null : Uint8List.fromList(bytes);
  final AndroidNativeAssociationBackend owner;
  final int token;
  final Uint8List? _bytes;
  bool _closed = false, _attempted = false;
  @override
  bool get isCurrent => !_closed && owner.isCurrent;
  @override
  Uint8List? get plaintext {
    if (!isCurrent) {
      credentialFail(ExternalCredentialFailure.temporarilyUnavailable);
    }
    return _bytes == null ? null : Uint8List.fromList(_bytes);
  }

  @override
  Future<void> commit(Uint8List plaintext) async {
    if (!isCurrent || _attempted) {
      credentialFail(ExternalCredentialFailure.staleRevision);
    }
    if (plaintext.isEmpty ||
        plaintext.length > AndroidAssociationStore.maxBytes) {
      credentialFail(ExternalCredentialFailure.resourceLimit);
    }
    _attempted = true;
    final result = await owner
        ._call('associationCommit', {'lease': token, 'plaintext': plaintext});
    if (result != true) {
      owner.invalidate();
      credentialFail(ExternalCredentialFailure.commitUnknown);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _bytes?.fillRange(0, _bytes.length, 0);
    try {
      // Cleanup is attempted even when ordinary operations have been invalidated.
      final result =
          await owner.calls.invoke('associationClose', {'lease': token});
      if (result != true) {
        credentialFail(ExternalCredentialFailure.commitUnknown);
      }
    } catch (_) {
      owner.invalidate();
      credentialFail(ExternalCredentialFailure.commitUnknown);
    } finally {
      owner._occupied = false;
    }
  }
}
