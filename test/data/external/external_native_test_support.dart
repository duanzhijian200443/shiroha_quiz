import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:shiroha_quiz/data/external/native/external_native_bindings.dart';

/// Test-only allocator + fake calls. Never opens the production helper, calls
/// DPAPI, reads credentials or implements an Application authentication backend.
final class FakeExternalNativeCalls
    implements
        ExternalNativeCalls,
        ExternalNativeCredentialCalls,
        ExternalNativeExchangeCalls,
        ExternalNativeExchangeConsumptionCalls,
        ExternalNativeDiscoveryCalls {
  FakeExternalNativeCalls() {
    final library = Platform.isWindows
        ? DynamicLibrary.open('msvcrt.dll')
        : DynamicLibrary.process();
    _calloc = library.lookupFunction<Pointer<Void> Function(UintPtr, UintPtr),
        Pointer<Void> Function(int, int)>('calloc');
    _free = library.lookupFunction<Void Function(Pointer<Void>),
        void Function(Pointer<Void>)>('free');
  }

  late final Pointer<Void> Function(int, int) _calloc;
  late final void Function(Pointer<Void>) _free;
  final allocations = <int, int>{};
  final freed = <int>[];
  final events = <String>[];
  void Function()? onSuccessfulOwnerClose;
  final discoveryFiles = <int, Uint8List>{};
  int discoveryStatus = 0, discoveryPublishes = 0;
  bool throwDiscovery = false;
  void Function(int)? beforeDiscoveryRead, beforeDiscoveryPublish;
  @override
  int discoveryPublish(
      int version, int owner, int kind, Pointer<Uint8> input, int length) {
    if (version != 3 || owners[owner] != 1 || ![1, 2, 3].contains(kind)) {
      return 1;
    }
    beforeDiscoveryPublish?.call(kind);
    if (discoveryStatus != 0) return discoveryStatus;
    final bytes = Uint8List.fromList(input.asTypedList(length));
    final previous = discoveryFiles[kind];
    if (kind != 1 &&
        previous != null &&
        previous.toString() != bytes.toString()) {
      return 5;
    }
    events.add('discovery:$kind');
    discoveryPublishes++;
    discoveryFiles[kind] = bytes;
    if (throwDiscovery) throw StateError('synthetic Discovery failure');
    return 0;
  }

  @override
  int discoveryRead(int version, int owner, int kind, Pointer<Uint8> output,
      int capacity, Pointer<Uint64> written) {
    written.value = 0;
    if (version != 3 ||
        !owners.containsKey(owner) ||
        ![1, 2, 3].contains(kind)) {
      return 1;
    }
    beforeDiscoveryRead?.call(kind);
    if (discoveryStatus != 0) return discoveryStatus;
    final bytes = discoveryFiles[kind];
    if (bytes == null) return 6;
    if (bytes.isEmpty || bytes.length > capacity) return 5;
    output.asTypedList(bytes.length).setAll(0, bytes);
    written.value = outputLength ?? bytes.length;
    return 0;
  }

  Uint8List result = Uint8List.fromList([9, 8, 7]);
  int version = 3, status = 0, allocationCount = 0, operationCount = 0;
  int? failAllocation, outputLength;
  bool throwOperation = false;
  Uint8List? capturedInput;
  final owners = <int, int>{};
  int nextToken = 1, ownerStatus = 0, closeStatus = 0;
  bool invalidOwnerResult = false,
      throwValidate = false,
      throwFree = false,
      throwClose = false;
  bool associationCrypto = false, unknownAfterCommit = false;
  bool throwAssociationBegin = false,
      throwAssociationAfterCommit = false,
      throwAssociationAbort = false;
  Uint8List? associationFile;
  int associationReadStatus = 0, associationCommitStatus = 0, commits = 0;
  int nextTicket = 1;
  final tickets = <int, int>{};

  final credentialFiles = <int, Uint8List>{};
  void Function(int kind)? beforeCredentialBegin;
  void Function(int kind)? afterCredentialCommit;
  void Function()? afterAssociationCommit;
  final exchangeFiles = <(int, String), Uint8List>{};
  final exchangeIdentities = <(int, String), int>{};
  final exchangeReceipts = <int, (int, (int, String), int)>{};
  int nextExchangeIdentity = 1, unknownExchangeEntries = 0, exchangeDeletes = 0;
  int exchangeStatus = 0;
  bool throwExchange = false;
  @override
  bool exchangeConsumptionAvailable = true;
  final exchangeReadTickets = <String, (int, (int, String), int, Uint8List)>{};
  int exchangeReleases = 0, exchangeConsumes = 0;
  int consumptionStatus = 0, releaseStatus = 0;
  void Function(int kind)? beforeExchangeConsume;
  bool throwReadBegin = false,
      throwConsume = false,
      throwRelease = false,
      invalidReadTicket = false;
  String _readToken(Pointer<Uint8> ticket) => ticket.asTypedList(24).join(',');
  @override
  int exchangeReadBegin(
      int version,
      int owner,
      int kind,
      Pointer<Uint8> id,
      Pointer<Uint8> output,
      int capacity,
      Pointer<Uint64> written,
      Pointer<Uint8> ticket) {
    ticket.asTypedList(24).fillRange(0, 24, 0);
    if (exchangeReadTickets.values.where((r) => r.$1 == owner).length >= 32) {
      written.value = 0;
      return 3;
    }
    final status =
        exchangeRead(version, owner, kind, id, output, capacity, written);
    if (status != 0) return status;
    ticket.cast<Uint64>().value = nextTicket++;
    ticket.asTypedList(24).fillRange(8, 24, 42);
    final key = (kind, _exchangeId(id));
    exchangeReadTickets[_readToken(ticket)] = (
      owner,
      key,
      exchangeIdentities[key]!,
      Uint8List.fromList(exchangeFiles[key]!)
    );
    if (throwReadBegin) throw StateError('synthetic acquire unknown');
    if (invalidReadTicket) ticket.asTypedList(24).fillRange(0, 24, 0);
    return 0;
  }

  @override
  int exchangeConsume(int version, int owner, Pointer<Uint8> ticket) {
    final key = _readToken(ticket);
    final r = exchangeReadTickets[key];
    if (r == null || r.$1 != owner || !owners.containsKey(owner)) return 1;
    exchangeReadTickets.remove(key);
    exchangeConsumes++;
    beforeExchangeConsume?.call(r.$2.$1);
    if (throwConsume) throw StateError('synthetic deletion unknown');
    if (consumptionStatus != 0) return consumptionStatus;
    if (exchangeFiles.length + unknownExchangeEntries > 32 ||
        exchangeIdentities[r.$2] != r.$3) {
      return 4;
    }
    final current = exchangeFiles[r.$2];
    if (current == null ||
        current.length != r.$4.length ||
        !List.generate(current.length, (i) => current[i] == r.$4[i])
            .every((v) => v)) {
      return 5;
    }
    exchangeFiles.remove(r.$2);
    exchangeIdentities.remove(r.$2);
    exchangeDeletes++;
    return 0;
  }

  @override
  int exchangeRelease(int version, int owner, Pointer<Uint8> ticket) {
    final key = _readToken(ticket);
    final r = exchangeReadTickets[key];
    if (r == null || r.$1 != owner || !owners.containsKey(owner)) return 1;
    exchangeReadTickets.remove(key);
    exchangeReleases++;
    if (throwRelease) throw StateError('synthetic release failure');
    return releaseStatus;
  }

  String _exchangeId(Pointer<Uint8> id) =>
      id.asTypedList(16).map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  @override
  int exchangeCreate(int version, int owner, int kind, Pointer<Uint8> id,
      Pointer<Uint8> input, int length, Pointer<Uint64> receipt) {
    receipt.value = 0;
    if (owners[owner] != (kind == 2 ? 1 : 2) || ![1, 2, 3].contains(kind)) {
      return 1;
    }
    if (exchangeStatus != 0) return exchangeStatus;
    if (exchangeFiles.length + unknownExchangeEntries >= 32) return 4;
    final key = (kind, _exchangeId(id));
    if (exchangeFiles.containsKey(key)) return 4;
    exchangeFiles[key] = Uint8List.fromList(input.asTypedList(length));
    final identity = nextExchangeIdentity++;
    exchangeIdentities[key] = identity;
    receipt.value = nextTicket++;
    exchangeReceipts[receipt.value] = (owner, key, identity);
    if (throwExchange) throw StateError('synthetic private Exchange');
    return 0;
  }

  @override
  int exchangeRead(int version, int owner, int kind, Pointer<Uint8> id,
      Pointer<Uint8> output, int capacity, Pointer<Uint64> written) {
    written.value = 0;
    if (!owners.containsKey(owner) || owners[owner] == (kind == 2 ? 1 : 2)) {
      return 1;
    }
    if (exchangeStatus != 0) return exchangeStatus;
    if (throwExchange) throw StateError('synthetic private Exchange');
    if (exchangeFiles.length + unknownExchangeEntries > 32) return 4;
    final bytes = exchangeFiles[(kind, _exchangeId(id))];
    if (bytes == null) return 6;
    if (bytes.isEmpty || bytes.length > capacity) return 5;
    output.asTypedList(bytes.length).setAll(0, bytes);
    written.value = outputLength ?? bytes.length;
    return 0;
  }

  @override
  int exchangeCleanup(int version, int owner, int receipt) {
    final r = exchangeReceipts[receipt];
    if (r == null || r.$1 != owner) return 1;
    exchangeReceipts.remove(receipt);
    if (throwExchange) throw StateError('synthetic private Exchange');
    if (exchangeStatus != 0) return exchangeStatus;
    if (exchangeIdentities[r.$2] != r.$3) return 4;
    exchangeFiles.remove(r.$2);
    exchangeIdentities.remove(r.$2);
    exchangeDeletes++;
    return 0;
  }

  final credentialTickets = <int, (int, int)>{};
  int credentialAborts = 0;
  @override
  int credentialBegin(int version, int owner, int kind, Pointer<Uint8> output,
      int capacity, Pointer<Uint64> written, Pointer<Uint64> ticket) {
    beforeCredentialBegin?.call(kind);
    written.value = 0;
    ticket.value = 0;
    if (![1, 2, 4].contains(kind) || owners[owner] != (kind == 4 ? 2 : 1)) {
      return 1;
    }
    if (ownerStatus != 0) return ownerStatus;
    if (tickets.containsValue(owner) ||
        credentialTickets.values.any((v) => v.$1 == owner)) {
      return 3;
    }
    if (associationReadStatus != 0) return associationReadStatus;
    ticket.value = nextTicket++;
    credentialTickets[ticket.value] = (owner, kind);
    if (throwAssociationBegin) throw StateError('synthetic private begin');
    final bytes = credentialFiles[kind];
    if (bytes == null) return 6;
    if (bytes.isEmpty || bytes.length > capacity) {
      credentialTickets.remove(ticket.value);
      ticket.value = 0;
      return 5;
    }
    output.asTypedList(bytes.length).setAll(0, bytes);
    written.value = bytes.length;
    return 0;
  }

  @override
  int credentialCommit(
      int version, int owner, int ticket, Pointer<Uint8> input, int length) {
    final entry = credentialTickets.remove(ticket);
    if (entry == null || entry.$1 != owner) return 1;
    if (associationCommitStatus != 0) return associationCommitStatus;
    credentialFiles[entry.$2] = Uint8List.fromList(input.asTypedList(length));
    events.add('credential:${entry.$2}');
    commits++;
    afterCredentialCommit?.call(entry.$2);
    if (throwAssociationAfterCommit) {
      throw StateError('synthetic private commit');
    }
    return unknownAfterCommit ? 7 : 0;
  }

  @override
  int credentialAbort(int version, int owner, int ticket) {
    credentialAborts++;
    final entry = credentialTickets.remove(ticket);
    if (throwAssociationAbort) throw StateError('synthetic private abort');
    return entry?.$1 == owner ? 0 : 1;
  }

  @override
  int associationBegin(int version, int owner, Pointer<Uint8> output,
      int capacity, Pointer<Uint64> written, Pointer<Uint64> ticket) {
    written.value = 0;
    ticket.value = 0;
    if (owners[owner] != 1 || ownerStatus != 0) return 4;
    if (tickets.containsValue(owner)) return 3;
    if (associationReadStatus != 0) return associationReadStatus;
    ticket.value = nextTicket++;
    tickets[ticket.value] = owner;
    if (throwAssociationBegin) {
      throw StateError('synthetic private begin detail');
    }
    final bytes = associationFile;
    if (bytes == null) return 6;
    output.asTypedList(bytes.length).setAll(0, bytes);
    written.value = bytes.length;
    return 0;
  }

  @override
  int associationCommit(
      int version, int owner, int ticket, Pointer<Uint8> input, int length) {
    if (tickets.remove(ticket) != owner) return 1;
    if (ownerStatus != 0 || !owners.containsKey(owner)) return 4;
    if (associationCommitStatus != 0) return associationCommitStatus;
    associationFile = Uint8List.fromList(input.asTypedList(length));
    commits++;
    afterAssociationCommit?.call();
    if (throwAssociationAfterCommit) {
      throw StateError('synthetic private commit detail');
    }
    return unknownAfterCommit ? 7 : 0;
  }

  @override
  int associationAbort(int version, int owner, int ticket) {
    final result = tickets.remove(ticket) == owner ? 0 : 1;
    if (throwAssociationAbort) {
      throw StateError('synthetic private abort detail');
    }
    return result;
  }

  @override
  int abiVersion() {
    events.add('version');
    return version;
  }

  @override
  Pointer<Uint8> allocate(int capacity) {
    events.add('allocate');
    if (++allocationCount == failAllocation) return nullptr;
    final pointer = _calloc(1, capacity).cast<Uint8>();
    if (pointer != nullptr) allocations[pointer.address] = capacity;
    return pointer;
  }

  @override
  void free(Pointer<Uint8> buffer) {
    final capacity = allocations.remove(buffer.address)!;
    buffer.asTypedList(capacity).fillRange(0, capacity, 0);
    freed.add(buffer.address);
    _free(buffer.cast<Void>());
    if (throwFree) throw StateError('synthetic private release detail');
  }

  @override
  int acquireOwner(int version, int role, Pointer<Uint64> token) {
    events.add('acquire:$role');
    token.value = 0;
    if (owners.containsValue(role)) return 4;
    if (ownerStatus != 0) return ownerStatus;
    if (invalidOwnerResult) return 0;
    token.value = nextToken++;
    owners[token.value] = role;
    if (throwOperation) throw StateError('synthetic private native detail');
    return 0;
  }

  @override
  int validateOwner(int version, int token) {
    events.add('validate');
    if (throwValidate) throw StateError('synthetic private handle detail');
    return owners.containsKey(token) ? ownerStatus : 1;
  }

  @override
  int closeOwner(int version, int token) {
    events.add('close');
    if (!owners.containsKey(token)) return 1;
    owners.remove(token);
    tickets.removeWhere((_, owner) => owner == token);
    credentialTickets.removeWhere((_, entry) => entry.$1 == token);
    exchangeReceipts.removeWhere((_, entry) => entry.$1 == token);
    exchangeReadTickets.removeWhere((_, entry) => entry.$1 == token);
    if (throwClose) throw StateError('synthetic private close detail');
    if (closeStatus == 0) onSuccessfulOwnerClose?.call();
    return closeStatus;
  }

  int _result(Pointer<Uint8> output, Pointer<Uint64> written) {
    operationCount++;
    output.asTypedList(result.length).setAll(0, result);
    written.value = outputLength ?? result.length;
    if (throwOperation) throw StateError('synthetic private OS detail');
    return status;
  }

  @override
  int localAppData(int version, Pointer<Uint8> output, int capacity,
          Pointer<Uint64> written) =>
      _result(output, written);

  @override
  int protect(int version, Pointer<Uint8> input, int length,
      Pointer<Uint8> output, int capacity, Pointer<Uint64> written) {
    capturedInput = Uint8List.fromList(input.asTypedList(length));
    if (associationCrypto) {
      final bytes = [0xda, 1, ...capturedInput!];
      output.asTypedList(bytes.length).setAll(0, bytes);
      written.value = bytes.length;
      return status;
    }
    return _result(output, written);
  }

  @override
  int unprotect(int version, Pointer<Uint8> input, int length,
      Pointer<Uint8> output, int capacity, Pointer<Uint64> written) {
    if (associationCrypto) {
      final bytes = input.asTypedList(length);
      if (length < 2 || bytes[0] != 0xda || bytes[1] != 1) return 5;
      output.asTypedList(length - 2).setAll(0, bytes.sublist(2));
      written.value = length - 2;
      return status;
    }
    return protect(version, input, length, output, capacity, written);
  }
}
