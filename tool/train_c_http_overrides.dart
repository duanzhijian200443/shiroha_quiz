import 'dart:async';
import 'dart:io';

import 'train_c_http_observer.dart';

/// Installs a tool-only transparent observation boundary for dart:io.
///
/// [super.createHttpClient] constructs the real dart:io client. The returned
/// delegating client forwards every transport setting and request operation;
/// it does not resolve DNS, change URIs, follow redirects, inspect bodies or
/// replace production socket/TLS policy.
final class TrainCHttpOverrides extends HttpOverrides {
  TrainCHttpOverrides(this.ledger);

  final TrainCRequestLedger ledger;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return TrainCObservedHttpClient(
      super.createHttpClient(context),
      ledger,
    );
  }
}

/// A complete, setter-preserving [HttpClient] delegation wrapper.
final class TrainCObservedHttpClient implements HttpClient {
  TrainCObservedHttpClient(this._inner, this._ledger);

  final HttpClient _inner;
  final TrainCRequestLedger _ledger;

  Future<HttpClientRequest> _open(
    String method,
    Future<HttpClientRequest> Function() operation,
  ) async {
    final eventIndex = _ledger.recordDispatchMethod(method);
    final stopwatch = Stopwatch()..start();
    try {
      final request = await operation();
      unawaited(_observeResponse(request.done, eventIndex, stopwatch));
      return request;
    } catch (_) {
      _ledger.recordNetworkFailure(
        eventIndex: eventIndex,
        durationMs: stopwatch.elapsedMilliseconds,
      );
      rethrow;
    }
  }

  Future<void> _observeResponse(
    Future<HttpClientResponse> responseFuture,
    int eventIndex,
    Stopwatch stopwatch,
  ) async {
    try {
      final response = await responseFuture;
      _ledger.recordResponse(
        eventIndex: eventIndex,
        statusCode: response.statusCode,
        durationMs: stopwatch.elapsedMilliseconds,
      );
    } catch (_) {
      _ledger.recordNetworkFailure(
        eventIndex: eventIndex,
        durationMs: stopwatch.elapsedMilliseconds,
      );
    }
  }

  @override
  Duration get idleTimeout => _inner.idleTimeout;

  @override
  set idleTimeout(Duration value) => _inner.idleTimeout = value;

  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;

  @override
  set connectionTimeout(Duration? value) => _inner.connectionTimeout = value;

  @override
  int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;

  @override
  set maxConnectionsPerHost(int? value) => _inner.maxConnectionsPerHost = value;

  @override
  bool get autoUncompress => _inner.autoUncompress;

  @override
  set autoUncompress(bool value) => _inner.autoUncompress = value;

  @override
  String? get userAgent => _inner.userAgent;

  @override
  set userAgent(String? value) => _inner.userAgent = value;

  @override
  Future<HttpClientRequest> open(
    String method,
    String host,
    int port,
    String path,
  ) =>
      _open(method, () => _inner.open(method, host, port, path));

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      _open(method, () => _inner.openUrl(method, url));

  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      _open('GET', () => _inner.get(host, port, path));

  @override
  Future<HttpClientRequest> getUrl(Uri url) =>
      _open('GET', () => _inner.getUrl(url));

  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      _open('POST', () => _inner.post(host, port, path));

  @override
  Future<HttpClientRequest> postUrl(Uri url) =>
      _open('POST', () => _inner.postUrl(url));

  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      _open('PUT', () => _inner.put(host, port, path));

  @override
  Future<HttpClientRequest> putUrl(Uri url) =>
      _open('PUT', () => _inner.putUrl(url));

  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      _open('DELETE', () => _inner.delete(host, port, path));

  @override
  Future<HttpClientRequest> deleteUrl(Uri url) =>
      _open('DELETE', () => _inner.deleteUrl(url));

  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      _open('PATCH', () => _inner.patch(host, port, path));

  @override
  Future<HttpClientRequest> patchUrl(Uri url) =>
      _open('PATCH', () => _inner.patchUrl(url));

  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      _open('HEAD', () => _inner.head(host, port, path));

  @override
  Future<HttpClientRequest> headUrl(Uri url) =>
      _open('HEAD', () => _inner.headUrl(url));

  @override
  set authenticate(
    Future<bool> Function(Uri url, String scheme, String? realm)? value,
  ) {
    _inner.authenticate = value;
  }

  @override
  void addCredentials(
    Uri url,
    String realm,
    HttpClientCredentials credentials,
  ) {
    _inner.addCredentials(url, realm, credentials);
  }

  @override
  set connectionFactory(
    Future<ConnectionTask<Socket>> Function(
      Uri url,
      String? proxyHost,
      int? proxyPort,
    )? value,
  ) {
    _inner.connectionFactory = value;
  }

  @override
  set findProxy(String Function(Uri url)? value) {
    _inner.findProxy = value;
  }

  @override
  set authenticateProxy(
    Future<bool> Function(String host, int port, String scheme, String? realm)?
        value,
  ) {
    _inner.authenticateProxy = value;
  }

  @override
  void addProxyCredentials(
    String host,
    int port,
    String realm,
    HttpClientCredentials credentials,
  ) {
    _inner.addProxyCredentials(host, port, realm, credentials);
  }

  @override
  set badCertificateCallback(
    bool Function(X509Certificate cert, String host, int port)? value,
  ) {
    _inner.badCertificateCallback = value;
  }

  @override
  set keyLog(Function(String line)? value) {
    _inner.keyLog = value;
  }

  @override
  void close({bool force = false}) {
    _inner.close(force: force);
  }
}
