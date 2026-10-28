/// Test-facility support for the two independent Windows pairing host windows.
///
/// Only public P27/P22 data and fixed stage names are exchanged. No private
/// key, Pin, Session or exception body crosses the bounded link directory.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/application/external/external_credential_association.dart';
import 'package:shiroha_quiz/data/external/windows_exchange_file_store.dart';

import 'mcp_vnext_windows_app_smoke.dart' show smokeDataPaths;

const pairingHostRootDefine = 'SHIROHA_MCP_APP_SMOKE_ROOT';
const pairingHostScenarioFile = 'scenario';
const pairingHostPaired = 'paired';
const pairingHostPeerAbort = 'peer-abort';

/// The public-only link files. Each is published by rename and read once.
abstract final class PairingLinkFile {
  static const submissionId = 'bridge-submission';
  static const submission = 'submission.exchange';
  static const challenge = 'challenge.exchange';
  static const trust = 'app-trust';
  static const initialDigest = 'app-initial-digest';
  static const bridgeInitialDigest = 'bridge-initial-digest';
  static const proofExchange = 'proof.exchange';
  static const proofPublished = 'bridge-proof';
  static const completion = 'app-completion';
  static const completionMeta = 'app-completion-meta';
  static const approved = 'app-approved';
  static const saved = 'bridge-saved';
}

/// Reuses the existing smoke isolation rules: an explicitly prepared,
/// task-owned immediate temporary child with the functional-smoke marker.
Directory pairingHostRoot(String root) {
  final paths = smokeDataPaths(root);
  return Directory(paths.applicationSupportRoot);
}

/// Test-only scenario selection written by the bounded controller. It is not a
/// production switch, environment variable or command-line option.
Future<String> pairingHostScenario(Directory root) async {
  final file = File(p.join(root.path, pairingHostScenarioFile));
  if (!await file.exists()) return pairingHostPaired;
  final value = (await file.readAsString()).trim();
  if (value != pairingHostPaired && value != pairingHostPeerAbort) {
    throw StateError('Pairing host scenario unavailable');
  }
  return value;
}

final class PairingHostEvidence {
  PairingHostEvidence(this.file) {
    if (file.existsSync()) {
      throw StateError('Pairing host evidence must be fresh');
    }
    file.createSync(recursive: true);
  }

  final File file;
  final _clock = Stopwatch()..start();
  int _sequence = 0;

  void record(String stage, [Map<String, Object?> extra = const {}]) {
    final safe = <String, Object?>{
      for (final entry in extra.entries)
        if (entry.value is int || entry.value is bool || entry.value is String)
          entry.key: entry.value,
    };
    file.writeAsStringSync(
        '${jsonEncode({
              'sequence': ++_sequence,
              'elapsedMs': _clock.elapsedMilliseconds,
              'stage': stage,
              ...safe,
            })}\n',
        mode: FileMode.append,
        flush: true);
  }

  bool get completed {
    if (!file.existsSync()) return false;
    return file
        .readAsLinesSync()
        .any((line) => line.contains('"stage":"script_complete"'));
  }
}

/// One bounded directory shared by the two evidence processes.
///
/// This is a TEST ONLY public-data carrier; it is not a production Pairing IPC
/// and carries no private key, credential object or Session material.
final class PairingHostLink {
  PairingHostLink(this.root);

  final Directory root;

  Future<void> prepare() => root.create(recursive: true);

  Future<void> publish(String name, List<int> bytes) async {
    final temp = File(p.join(root.path, '$name.writing'));
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(p.join(root.path, name));
  }

  Future<void> publishText(String name, String value) =>
      publish(name, utf8.encode(value));

  Future<File?> readIfPresent(String name) async {
    final file = File(p.join(root.path, name));
    return await file.exists() ? file : null;
  }

  Future<File> wait(String name,
      {Duration timeout = const Duration(seconds: 60)}) async {
    final file = File(p.join(root.path, name));
    final watch = Stopwatch()..start();
    while (!await file.exists()) {
      if (watch.elapsed >= timeout) {
        throw StateError('Public pairing link timed out: $name');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return file;
  }

  Future<String> waitText(String name,
          {Duration timeout = const Duration(seconds: 60)}) async =>
      (await wait(name, timeout: timeout)).readAsString();

  Future<String?> readTextIfPresent(String name) async =>
      (await readIfPresent(name))?.readAsString();
}

/// Minimal real-application driver: finds rendered text/fields, scrolls them
/// into view, dispatches genuine pointer events and captures the window.
final class PairingUiDriver {
  PairingUiDriver(this.surfaceKey);

  final GlobalKey surfaceKey;
  int _pointer = 1;

  List<Element> _matches(bool Function(Widget) test) {
    final found = <Element>[];
    void visit(Element element) {
      if (test(element.widget)) found.add(element);
      element.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    return found;
  }

  bool hasText(String text) => _matches(_text(text)).isNotEmpty;

  Future<void> scrollToBottom() async {
    final watch = Stopwatch()..start();
    while (watch.elapsed < const Duration(seconds: 10)) {
      for (final element in _matches((widget) => widget is Scrollable)) {
        final scrollable =
            (element as StatefulElement).state as ScrollableState;
        final position = scrollable.position;
        if (!position.hasContentDimensions) continue;
        if (position.maxScrollExtent > position.pixels) {
          await position.animateTo(position.maxScrollExtent,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut);
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw StateError('UI scroll surface unavailable');
  }

  static bool Function(Widget) _text(String text) => (widget) =>
      (widget is Text && widget.data == text) ||
      (widget is SelectableText && widget.data == text);

  Future<Element> waitText(String text,
          {Duration timeout = const Duration(seconds: 60),
          bool last = false}) =>
      _wait(_text(text), text, timeout: timeout, last: last);

  Future<Element> waitField(String label,
          {Duration timeout = const Duration(seconds: 60)}) =>
      _wait(
          (widget) =>
              widget is TextField && widget.decoration?.labelText == label,
          label,
          timeout: timeout);

  Future<Element> _wait(bool Function(Widget) test, String name,
      {required Duration timeout, bool last = false}) async {
    final watch = Stopwatch()..start();
    while (watch.elapsed < timeout) {
      final matches = _matches(test);
      if (matches.isNotEmpty) return last ? matches.last : matches.first;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw StateError('UI element unavailable: $name');
  }

  Future<void> tapText(String text,
      {Duration timeout = const Duration(seconds: 60)}) async {
    final element = await waitText(text, timeout: timeout, last: true);
    await _tapElement(element, text);
  }

  /// Taps only an actually enabled button; a bounded refresh may still be
  /// enabling it, so waiting must not click a disabled control.
  Future<void> tapButton(String text,
      {Duration timeout = const Duration(seconds: 60)}) async {
    final watch = Stopwatch()..start();
    while (watch.elapsed < timeout) {
      for (final element in _matches(_text(text)).reversed) {
        if (_button(element)?.onPressed != null) {
          await _tapElement(element, text);
          return;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw StateError('UI button unavailable: $text');
  }

  ButtonStyleButton? _button(Element element) {
    ButtonStyleButton? result;
    element.visitAncestorElements((ancestor) {
      if (ancestor.widget case final ButtonStyleButton button) {
        result = button;
        return false;
      }
      return true;
    });
    return result;
  }

  Future<void> _tapElement(Element element, String name) async {
    await Scrollable.ensureVisible(element,
        alignment: 0.5, duration: const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final render = element.renderObject;
    if (render is! RenderBox || !render.hasSize) {
      throw StateError('UI element not laid out: $name');
    }
    final position = render.localToGlobal(render.size.center(Offset.zero));
    final pointer = _pointer++;
    GestureBinding.instance.handlePointerEvent(PointerDownEvent(
        pointer: pointer,
        position: position,
        kind: PointerDeviceKind.mouse,
        buttons: kPrimaryButton,
        device: 1));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    GestureBinding.instance.handlePointerEvent(PointerUpEvent(
        pointer: pointer,
        position: position,
        kind: PointerDeviceKind.mouse,
        device: 1));
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }

  Future<void> enterField(String label, String value) async {
    final element = await waitField(label);
    final field = element.widget as TextField;
    final controller = field.controller;
    if (controller == null) throw StateError('UI field is not editable');
    controller.value = TextEditingValue(text: value);
    // A plain controller update does not rebuild the owning control; its own
    // bounded refresh does, which is also what enables the next button.
    await Future<void>.delayed(const Duration(milliseconds: 1200));
  }

  Future<String> waitKeyedText(Key key,
      {Duration timeout = const Duration(seconds: 60)}) async {
    final watch = Stopwatch()..start();
    while (watch.elapsed < timeout) {
      final value = keyedText(key);
      if (value != null) return value;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw StateError('UI text unavailable');
  }

  String? keyedText(Key key) {
    final matches = _matches((widget) {
      if (widget.key != key) return false;
      return widget is SelectableText || widget is Text;
    });
    if (matches.isEmpty) return null;
    final widget = matches.first.widget;
    return widget is SelectableText ? widget.data : (widget as Text).data;
  }

  Future<void> screenshot(String path) async {
    await WidgetsBinding.instance.endOfFrame;
    final boundary = surfaceKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) {
      throw StateError('UI surface unavailable');
    }
    final image = await boundary.toImage();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw StateError('UI surface capture unavailable');
      await File(path).writeAsBytes(bytes.buffer.asUint8List(), flush: true);
    } finally {
      image.dispose();
    }
  }
}

/// Keeps a host failure visible without exporting private exception details.
/// Only the bounded message of a local StateError is retained.
String safeFailure(Object error) => switch (error) {
      StateError(:final message) =>
        'state:${message.length > 120 ? message.substring(0, 120) : message}',
      ExternalCredentialException(:final failure) =>
        'credential:${failure.name}',
      ExternalAuthException(:final failure) => 'auth:${failure.name}',
      ExternalExchangeException(:final failure) => 'exchange:${failure.name}',
      _ => 'type:${error.runtimeType}',
    };
