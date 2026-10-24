import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import '../../application/external/first_party_external_credentials.dart';
import 'first_party_bridge_pairing_control.dart';

/// One explicitly supplied Bridge port in its own window.
///
/// This surface holds no key, Enrollment, Pin, approval or Session authority;
/// the trusted host owns the original P27 controller and resource settlement.
/// Window close, owner exit and disposal all await the SAME single close.
final class BridgeHostSurface extends StatefulWidget {
  const BridgeHostSurface(
      {super.key,
      required this.port,
      required this.close,
      this.title = 'Shiroha Bridge'});

  final FirstPartyBridgePairingPort port;
  final Future<void> Function() close;
  final String title;

  @override
  State<BridgeHostSurface> createState() => _BridgeHostSurfaceState();
}

final class _BridgeHostSurfaceState extends State<BridgeHostSurface> {
  late AppLifecycleListener _listener;
  late Future<void> Function() _closeCallback;
  Future<void>? _closing;
  String? _failure;

  @override
  void initState() {
    super.initState();
    _closeCallback = widget.close;
    _listener = _listen();
  }

  AppLifecycleListener _listen() => AppLifecycleListener(
        onExitRequested: () async {
          try {
            await _close();
            return AppExitResponse.exit;
          } catch (_) {
            // The original host retains custody; never report a false exit.
            if (mounted) setState(() => _failure = '关闭未确认，请等待本地宿主完成清理。');
            return AppExitResponse.cancel;
          }
        },
        onDetach: () => _detach(_close),
      );

  void _detach(Future<void> Function() close) {
    unawaited(Future<void>.sync(close).catchError((Object _) {}));
  }

  Future<void> _close() => _closing ??= _closeCallback();

  @override
  void didUpdateWidget(BridgeHostSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A rebuilt page keeps its original port AND its original close identity;
    // only a different port is a replacement, never a new Enrollment.
    if (!identical(oldWidget.port, widget.port)) {
      final previous = _closeCallback;
      _detach(() async {
        await oldWidget.port.close();
        await previous();
      });
      _listener.dispose();
      _closeCallback = widget.close;
      _listener = _listen();
      _closing = null;
      _failure = null;
    }
  }

  @override
  void dispose() {
    _listener.dispose();
    _detach(_close);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: widget.title,
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: Column(children: [
          if (_failure != null)
            Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_failure!,
                    key: const Key('bridge-host-close-failure'))),
          Expanded(child: FirstPartyBridgePairingControl(port: widget.port)),
        ]),
      ),
    );
  }
}
