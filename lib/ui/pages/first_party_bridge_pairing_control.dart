import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../application/external/first_party_external_credentials.dart';

/// Explicit independent Bridge local surface, with no default startup consumer.
/// The trusted host retains resource custody until the supplied port drains.
class FirstPartyBridgePairingControl extends StatefulWidget {
  const FirstPartyBridgePairingControl({super.key, required this.port});

  final FirstPartyBridgePairingPort port;

  @override
  State<FirstPartyBridgePairingControl> createState() =>
      _FirstPartyBridgePairingControlState();
}

class _FirstPartyBridgePairingControlState
    extends State<FirstPartyBridgePairingControl> {
  late final FirstPartyBridgePairingPort _port;
  final _label = TextEditingController(text: 'Shiroha Bridge');
  final _build = TextEditingController(text: 'local');
  final _trust = TextEditingController();
  final _completion = TextEditingController();
  FirstPartyBridgePairingDisplay _display =
      const FirstPartyBridgePairingDisplay();
  Timer? _timer;
  Future<void>? _closing;
  bool _initialCompared = false, _completionCompared = false;
  bool _busy = false, _stopped = false, _disposed = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _port = widget.port;
    _refresh();
    if (!_stopped) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted && !_disposed && !_stopped) setState(_refresh);
      });
    }
  }

  @override
  void didUpdateWidget(covariant FirstPartyBridgePairingControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.port, _port)) {
      // A new port needs a newly mounted surface, never old comparison choices.
      _withdraw(failed: true);
    }
  }

  Future<void> _closePort() => _closing ??= () async {
        try {
          await _port.close();
        } catch (_) {
          if (mounted && !_disposed) {
            setState(() => _message = '关闭未确认，请由本地宿主完成清理。');
          }
        }
      }();

  void _clearComparisons() {
    _initialCompared = false;
    _completionCompared = false;
  }

  void _withdraw({bool failed = false, bool pinSaved = false}) {
    _stopped = true;
    _busy = false;
    _timer?.cancel();
    _clearComparisons();
    _display = FirstPartyBridgePairingDisplay(closed: true, pinSaved: pinSaved);
    _trust.clear();
    _completion.clear();
    _message = pinSaved
        ? '凭据已保存；这不授予会话、权限或启用状态。'
        : failed
            ? '配对不可用或已过期。请关闭并由本地宿主重新建立流程。'
            : '配对已取消。';
    unawaited(_closePort());
  }

  void _refresh() {
    if (_stopped) return;
    try {
      final value = _port.display();
      if (value.closed) {
        _withdraw(failed: !value.pinSaved, pinSaved: value.pinSaved);
        return;
      }
      if (value.submissionId != _display.submissionId ||
          value.initialDigest != _display.initialDigest ||
          value.completionDigest != _display.completionDigest ||
          value.revision != _display.revision) {
        _clearComparisons();
      }
      _display = value;
    } catch (_) {
      _withdraw(failed: true);
    }
  }

  Future<void> _act(FutureOr<void> Function() action) async {
    if (_busy || _stopped) return;
    setState(() {
      _refresh();
      if (!_stopped) _busy = true;
    });
    if (_stopped) return;
    try {
      await action();
      if (mounted && !_disposed && !_stopped) setState(_refresh);
    } catch (_) {
      if (mounted && !_disposed && !_stopped) {
        setState(() => _withdraw(failed: true));
      }
    } finally {
      if (mounted && !_disposed && !_stopped) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _import({required bool completion}) => _act(() async {
        setState(_clearComparisons);
        final controller = completion ? _completion : _trust;
        final input = controller.text;
        controller.clear();
        if (completion) {
          await _port.importCompletion(input);
        } else {
          await _port.importTrust(input);
        }
      });

  Widget _input(TextEditingController controller, String label, int maxBytes,
      {bool multiline = false, bool enabled = true}) {
    return TextField(
      controller: controller,
      enabled: enabled && !_busy && !_stopped,
      decoration: InputDecoration(labelText: label),
      maxLength: maxBytes,
      maxLengthEnforcement: MaxLengthEnforcement.enforced,
      maxLines: multiline ? 4 : 1,
      autocorrect: false,
      enableSuggestions: false,
      inputFormatters: [
        TextInputFormatter.withFunction((oldValue, newValue) =>
            utf8.encode(newValue.text).length <= maxBytes
                ? newValue
                : oldValue),
      ],
      onChanged: (_) => setState(_clearComparisons),
    );
  }

  Widget _digest(String label, String digest) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label),
          SelectableText(digest,
              style: const TextStyle(fontFamily: 'monospace')),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final display = _display;
    final active = !_busy && !_stopped;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Bridge 本地配对', style: Theme.of(context).textTheme.titleLarge),
          const Text('仅在受信任的独立 Bridge 本地宿主使用。两次比较必须分别与 App 完整显示核对；导入不等于确认。'),
          if (_message != null) Text(_message!),
          if (!_stopped && display.submissionId == null) ...[
            _input(_label, '显示名称', 64),
            _input(_build, '客户端版本', 32),
            FilledButton(
              onPressed: active
                  ? () => _act(() => _port.beginEnrollment(
                      displayLabel: _label.text, clientBuild: _build.text))
                  : null,
              child: const Text('开始配对'),
            ),
          ],
          if (!_stopped && display.submissionId != null) ...[
            const Text('原 Submission ID（仅关联公共提交）'),
            SelectableText(display.submissionId!),
            TextButton.icon(
              onPressed: active
                  ? () => _act(() => Clipboard.setData(
                      ClipboardData(text: _display.submissionId!)))
                  : null,
              icon: const Icon(Icons.copy),
              label: const Text('复制 Submission ID'),
            ),
            if (display.initialDigest == null) ...[
              _input(_trust, '粘贴 App Trust 公共 JSON', 4096, multiline: true),
              FilledButton(
                onPressed: active && _trust.text.isNotEmpty
                    ? () => _import(completion: false)
                    : null,
                child: const Text('导入 Trust'),
              ),
            ],
            if (display.initialDigest != null) ...[
              _digest('初始信任摘要（完整 64 位）', display.initialDigest!),
              if (!display.proofPublished) ...[
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('我已与受信任 App 独立比较完整初始摘要，且完全相同'),
                  value: _initialCompared,
                  onChanged: active
                      ? (value) =>
                          setState(() => _initialCompared = value == true)
                      : null,
                ),
                FilledButton(
                  onPressed: active && _initialCompared
                      ? () => _act(() {
                            if (!_initialCompared) return;
                            _port.confirmInitial(_display.initialDigest!);
                            _clearComparisons();
                          })
                      : null,
                  child: const Text('确认初始比较并发布 Proof'),
                ),
              ],
            ],
            if (display.proofPublished) ...[
              const Text('Proof 已发布。请在 App 分别批准并完成验证，再导入其最新 Completion。'),
              if (display.completionDigest == null) ...[
                _input(_completion, '粘贴 App Completion 公共 JSON', 4096,
                    multiline: true),
                FilledButton(
                  onPressed: active && _completion.text.isNotEmpty
                      ? () => _import(completion: true)
                      : null,
                  child: const Text('导入 Completion'),
                ),
              ],
            ],
            if (display.completionDigest != null &&
                display.revision != null) ...[
              _digest('完成摘要（完整 64 位）', display.completionDigest!),
              Text('实际 Revision：${display.revision}'),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('我已再次独立比较 App 的完整完成摘要及实际 Revision，且均相同'),
                value: _completionCompared,
                onChanged: active
                    ? (value) =>
                        setState(() => _completionCompared = value == true)
                    : null,
              ),
              FilledButton(
                onPressed: active && _completionCompared
                    ? () => _act(() {
                          if (!_completionCompared) return;
                          _port.confirmCompletion(
                              _display.completionDigest!, _display.revision!);
                          _clearComparisons();
                        })
                    : null,
                child: const Text('确认完成比较并保存凭据'),
              ),
            ],
          ],
          if (_busy) const LinearProgressIndicator(),
          if (!_stopped)
            TextButton(
              onPressed: () => setState(() => _withdraw()),
              child: const Text('取消配对'),
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _stopped = true;
    _timer?.cancel();
    unawaited(_closePort());
    _label.dispose();
    _build.dispose();
    _trust.dispose();
    _completion.dispose();
    super.dispose();
  }
}
