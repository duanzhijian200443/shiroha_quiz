import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../../application/external/external_authorization.dart';
import '../../application/external/external_credential_association.dart';
import '../../application/external/external_credential_boundary.dart';
import '../../application/external/external_trust_core.dart';
import 'android_native_association_backend.dart';

Never androidLinkFail() => throw StateError('android_link_unavailable');
String androidNonce() =>
    base64UrlEncode(List<int>.generate(32, (_) => Random.secure().nextInt(256)))
        .replaceAll('=', '');

bool androidNonceIsValid(Object? value) {
  if (value is! String || !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value)) {
    return false;
  }
  try {
    final bytes = base64Url.decode('$value=');
    return bytes.length == 32 &&
        base64UrlEncode(bytes).replaceAll('=', '') == value;
  } catch (_) {
    return false;
  }
}

/// Bounded lexical validation before the SDK may fold duplicate JSON keys.
Map<String, dynamic> androidStrictObject(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > 6324224) androidLinkFail();
  final source = utf8.decode(bytes, allowMalformed: false);
  final stack = <Set<String>?>[];
  for (var i = 0; i < source.length; i++) {
    final unit = source.codeUnitAt(i);
    if (unit == 34) {
      final start = i++;
      while (i < source.length && source.codeUnitAt(i) != 34) {
        if (source.codeUnitAt(i) == 92) i++;
        i++;
      }
      if (i >= source.length) androidLinkFail();
      var next = i + 1;
      while (next < source.length && ' \r\n\t'.contains(source[next])) {
        next++;
      }
      if (next < source.length && source.codeUnitAt(next) == 58) {
        if (stack.isEmpty ||
            stack.last == null ||
            !stack.last!
                .add(jsonDecode(source.substring(start, i + 1)) as String)) {
          androidLinkFail();
        }
      }
    } else if (unit == 123 || unit == 91) {
      stack.add(unit == 123 ? <String>{} : null);
      if (stack.length > 32) androidLinkFail();
    } else if (unit == 125 || unit == 93) {
      if (stack.isEmpty || (unit == 125) != (stack.last != null)) {
        androidLinkFail();
      }
      stack.removeLast();
    }
  }
  if (stack.isNotEmpty) androidLinkFail();
  final decoded = jsonDecode(source);
  if (decoded is! Map<String, dynamic>) androidLinkFail();
  return decoded;
}

void androidFields(Map<String, dynamic> object, Set<String> fields) {
  if (object.length != fields.length || !fields.every(object.containsKey)) {
    androidLinkFail();
  }
}

/// Only a trusted platform event can construct this original channel handle.
final class AndroidNativeChannel {
  AndroidNativeChannel._(this.native, this.id, this.peer, this.installationId);
  final AndroidNativeCalls native;
  final String id, peer, installationId;
  bool _live = true;
  Future<void>? _closing;
  bool get live => _live;
  void invalidate() {
    _live = false;
  }

  Future<bool> attest() async {
    if (!_live) return false;
    try {
      final value = await native.invoke('attest',
          {'channel': id, 'peer': peer, 'installationId': installationId});
      if (value != true) invalidate();
    } catch (_) {
      invalidate();
    }
    return _live;
  }

  Future<void> established() async {
    if (!_live || await native.invoke('established', {'channel': id}) != true) {
      androidLinkFail();
    }
  }

  Future<void> peerClosed() async {
    if (!_live || await native.invoke('peerClosed', {'channel': id}) != true) {
      androidLinkFail();
    }
  }

  Future<void> proofStarted() async {
    if (!_live ||
        await native.invoke('proofStarted', {'channel': id}) != true) {
      androidLinkFail();
    }
  }

  Future<(int, Map<String, dynamic>)> read() async {
    if (!_live) androidLinkFail();
    final reply = await native.invoke('read', {'channel': id});
    if (!_live ||
        reply is! Map ||
        reply.length != 2 ||
        reply['kind'] is! int ||
        reply['payload'] is! Uint8List) {
      androidLinkFail();
    }
    // Borrowed codec storage can be immutable. Decode without mutating it or
    // allocating another full raw frame; the platform retains its own custody.
    final bytes = reply['payload'] as Uint8List;
    if (reply['kind'] == 1 && bytes.length > 16384) androidLinkFail();
    return (reply['kind'] as int, androidStrictObject(bytes));
  }

  Future<void> write(int kind, Map<String, dynamic> value) async {
    if (!_live) androidLinkFail();
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(value)));
    try {
      if (bytes.length > (kind == 1 ? 16384 : 524288) ||
          await native.invoke(
                  'write', {'channel': id, 'kind': kind, 'payload': bytes}) !=
              true ||
          !_live) {
        androidLinkFail();
      }
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  Future<void> close() {
    invalidate();
    return _closing ??= () async {
      if (await native.invoke('channelClose', {'channel': id}) != true) {
        androidLinkFail();
      }
    }();
  }
}

/// Native event ownership and private one-use P15 verification events.
final class AndroidChannelVerification
    implements
        ExternalCredentialVerificationPort,
        ExternalExistingCredentialVerificationPort {
  AndroidChannelVerification(this.native,
      {required this.elapsed,
      required this.current,
      required this.installationId,
      required this.expiresAt});
  final AndroidNativeCalls native;
  final Duration Function() elapsed;
  final bool Function() current;
  final String installationId;
  final DateTime expiresAt;
  final _channels = <String, AndroidNativeChannel>{};
  final _attempts = <_AndroidAttempt>{};
  bool _closed = false;

  AndroidNativeChannel accept(Map<String, Object?> nativeEvent) {
    final id = nativeEvent['channel'], peer = nativeEvent['peer'];
    if (_closed ||
        !current() ||
        id is! String ||
        !ExternalAuthLimits.validId(id) ||
        peer is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(peer) ||
        nativeEvent['installationId'] != installationId ||
        _channels.isNotEmpty) {
      androidLinkFail();
    }
    return _channels[id] =
        AndroidNativeChannel._(native, id, peer, installationId);
  }

  void invalidate(String id) {
    _channels[id]?.invalidate();
  }

  void invalidateAll() {
    for (final channel in _channels.values) {
      channel.invalidate();
    }
  }

  Future<void> retire(AndroidNativeChannel channel) async {
    channel.invalidate();
    for (final event
        in _attempts.where((e) => identical(e.channel, channel)).toList()) {
      event.invalid = true;
      _attempts.remove(event);
    }
    await channel.close();
    _channels.remove(channel.id);
  }

  Future<Object> event(
      AndroidNativeChannel channel, ExternalProfileReference reference,
      {required String purpose,
      required int revision,
      ExternalCredentialAssociationSnapshot? association}) async {
    if (!identical(_channels[channel.id], channel) ||
        !await channel.attest() ||
        !current() ||
        _closed) {
      androidLinkFail();
    }
    final value = _AndroidAttempt(
        this, channel, reference, purpose, revision, association, elapsed());
    _attempts.add(value);
    return value;
  }

  Future<bool> _verify(ExternalCredentialChallenge challenge, Object event,
      String purpose) async {
    if (event is! _AndroidAttempt ||
        !isLive(event) ||
        event.used ||
        event.purpose != purpose ||
        challenge.profileId != event.reference.profileId ||
        challenge.installationId != installationId ||
        challenge.credentialIdentity != event.channel.peer ||
        challenge.revision != event.revision ||
        (purpose == 'business'
            ? challenge.requestId != null
            : challenge.requestId == null)) {
      return false;
    }
    event.used = true;
    event.runtime = challenge.runtimeInstance;
    event.generation = challenge.generation;
    if (!await event.channel.attest()) event.invalid = true;
    return isLive(event);
  }

  @override
  Future<bool> verifyPairing(ExternalCredentialChallenge c, Object e) =>
      _verify(c, e, 'pairing');
  @override
  Future<bool> verifyAuthentication(ExternalCredentialChallenge c, Object e) =>
      _verify(c, e, 'business');
  @override
  Future<bool> verifyExistingCredential(
          ExternalCredentialChallenge c, Object e) =>
      _verify(c, e, 'enable-proof');
  @override
  bool isLive(Object event) {
    if (event is! _AndroidAttempt ||
        !identical(event.owner, this) ||
        !_attempts.contains(event)) {
      return false;
    }
    if (_closed ||
        !current() ||
        !event.channel.live ||
        !DateTime.now().toUtc().isBefore(expiresAt) ||
        (event.association != null && !event.association!.isCurrent) ||
        (event.session == null &&
            elapsed() - event.created >=
                ExternalCredentialBoundary.evidenceLifetime) ||
        (event.session != null &&
            (event.session!.failure != null ||
                event.session!.generation != event.generation))) {
      event.invalid = true;
    }
    return !event.invalid;
  }

  void bindSession(Object event, ExternalSession session) {
    if (event is! _AndroidAttempt ||
        !isLive(event) ||
        !event.used ||
        event.purpose != 'business') {
      androidLinkFail();
    }
    event.session = session;
  }

  Future<void> close() async {
    _closed = true;
    invalidateAll();
    for (final channel in _channels.values.toList()) {
      await retire(channel);
    }
  }
}

final class _AndroidAttempt {
  _AndroidAttempt(this.owner, this.channel, this.reference, this.purpose,
      this.revision, this.association, this.created);
  final AndroidChannelVerification owner;
  final AndroidNativeChannel channel;
  final ExternalProfileReference reference;
  final String purpose;
  final int revision;
  final ExternalCredentialAssociationSnapshot? association;
  final Duration created;
  Object? runtime;
  int? generation;
  ExternalSession? session;
  bool used = false, invalid = false;
}
