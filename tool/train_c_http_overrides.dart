import 'dart:async';
import 'dart:convert';
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
    // Opening a dart:io request establishes the request object/connection but
    // is not the frozen TRAIN C attempt-consumption boundary. The attempt is
    // consumed only when HttpClientRequest.close() is invoked.
    final request = await operation();
    return TrainCObservedHttpClientRequest(request, _ledger, method);
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

/// Delegates the complete request/IOSink surface while moving TRAIN C attempt
/// accounting to the frozen dispatch boundary: the first [close] call.
///
/// Headers and bodies are never inspected. A repeated close returns the same
/// observed future and cannot create a second ledger event.
final class TrainCObservedHttpClientRequest implements HttpClientRequest {
  TrainCObservedHttpClientRequest(this._inner, this._ledger, this._method);

  final HttpClientRequest _inner;
  final TrainCRequestLedger _ledger;
  final String _method;

  Future<HttpClientResponse>? _closeFuture;

  @override
  Future<HttpClientResponse> close() {
    final existing = _closeFuture;
    if (existing != null) return existing;

    final eventIndex = _ledger.recordDispatchMethod(_method);
    final stopwatch = Stopwatch()..start();
    late final Future<HttpClientResponse> observed;
    try {
      observed = _inner.close().then(
        (response) {
          _ledger.recordResponse(
            eventIndex: eventIndex,
            statusCode: response.statusCode,
            durationMs: stopwatch.elapsedMilliseconds,
          );
          return response;
        },
        onError: (Object error, StackTrace stackTrace) {
          _ledger.recordNetworkFailure(
            eventIndex: eventIndex,
            durationMs: stopwatch.elapsedMilliseconds,
          );
          Error.throwWithStackTrace(error, stackTrace);
        },
      );
    } catch (_) {
      _ledger.recordNetworkFailure(
        eventIndex: eventIndex,
        durationMs: stopwatch.elapsedMilliseconds,
      );
      rethrow;
    }
    _closeFuture = observed;
    return observed;
  }

  @override
  Future<HttpClientResponse> get done => _closeFuture ?? _inner.done;

  @override
  HttpHeaders get headers => _inner.headers;

  @override
  List<Cookie> get cookies => _inner.cookies;

  @override
  bool get persistentConnection => _inner.persistentConnection;

  @override
  set persistentConnection(bool value) => _inner.persistentConnection = value;

  @override
  bool get followRedirects => _inner.followRedirects;

  @override
  set followRedirects(bool value) => _inner.followRedirects = value;

  @override
  int get maxRedirects => _inner.maxRedirects;

  @override
  set maxRedirects(int value) => _inner.maxRedirects = value;

  @override
  int get contentLength => _inner.contentLength;

  @override
  set contentLength(int value) => _inner.contentLength = value;

  @override
  bool get bufferOutput => _inner.bufferOutput;

  @override
  set bufferOutput(bool value) => _inner.bufferOutput = value;

  @override
  Encoding get encoding => _inner.encoding;

  @override
  set encoding(Encoding value) => _inner.encoding = value;

  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;

  @override
  Uri get uri => _inner.uri;

  @override
  String get method => _inner.method;

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    _inner.abort(exception, stackTrace);
  }

  @override
  void add(List<int> data) => _inner.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    _inner.addError(error, stackTrace);
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) => _inner.addStream(stream);

  @override
  Future<void> flush() => _inner.flush();

  @override
  void write(Object? object) => _inner.write(object);

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) {
    _inner.writeAll(objects, separator);
  }

  @override
  void writeCharCode(int charCode) => _inner.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) => _inner.writeln(object);
}
