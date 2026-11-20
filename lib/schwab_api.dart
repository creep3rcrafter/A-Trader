/// Schwab OAuth and LEVELONE_EQUITIES streaming adapter.
///
/// The adapter emits market observations only. It has no order-placement
/// endpoint; all orders remain inside SimulatorEngine.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'historical_replay.dart';
import 'live_runtime.dart';
import 'secure_storage.dart';
import 'simulator.dart';

class SchwabApi {
  SchwabApi({
    required this.storage,
    required this.onQuote,
    required this.onState,
    HttpClient? httpClient,
  }) : _http = httpClient ?? HttpClient();

  static const authorizationEndpoint =
      'https://api.schwabapi.com/v1/oauth/authorize';
  static const tokenEndpoint = 'https://api.schwabapi.com/v1/oauth/token';
  static const apiBase = 'https://api.schwabapi.com';

  final SecureStorage storage;
  final void Function(LiveQuote quote) onQuote;
  final void Function(FeedState state, String reason) onState;
  final HttpClient _http;
  WebSocket? _socket;
  bool _stopping = false;
  List<String> _symbols = [];
  Set<String> _subscribedSymbols = {};
  Map<String, dynamic>? _activeStreamInfo;
  final Map<String, Completer<void>> _subscriptionUpdates = {};
  int _subscriptionRequestId = 2;
  final LevelOneQuoteMerger _quoteMerger = LevelOneQuoteMerger();

  Future<Map<String, String>> _secrets() => storage.load();

  Future<void> saveAppCredentials({
    required String appKey,
    required String appSecret,
    required String redirectUri,
  }) async {
    if (appKey.trim().isEmpty || appSecret.isEmpty) {
      throw ArgumentError('Schwab app key and secret are required.');
    }
    Map<String, String> old;
    try {
      old = await _secrets();
    } on SecureStorageException {
      // Replace credentials that this Windows user can no longer decrypt.
      old = {};
    }
    if (old['appKey'] != appKey.trim() || old['appSecret'] != appSecret) {
      old
        ..remove('accessToken')
        ..remove('refreshToken')
        ..remove('expiresAtMs')
        ..remove('oauthState');
    }
    old
      ..['appKey'] = appKey.trim()
      ..['appSecret'] = appSecret
      ..['redirectUri'] = redirectUri.trim();
    await storage.save(old);
  }

  Future<String> authorizationUrl() async {
    final secrets = await _secrets();
    final key = secrets['appKey'];
    final redirect = secrets['redirectUri'];
    if (key == null || redirect == null || redirect.isEmpty) {
      throw StateError('Save Schwab app credentials and callback URL first.');
    }
    final nonce = base64Url
        .encode(List<int>.generate(32, (_) => Random.secure().nextInt(256)))
        .replaceAll('=', '');
    secrets['oauthState'] = nonce;
    await storage.save(secrets);
    final uri = Uri.parse(authorizationEndpoint).replace(
      queryParameters: {
        'client_id': key,
        'redirect_uri': redirect,
        'response_type': 'code',
        'state': nonce,
      },
    );
    return uri.toString();
  }

  /// Completes OAuth from the URL Schwab redirected the browser to, whether it
  /// arrived at the local callback listener or was pasted by the user.
  Future<void> completeAuthorization(Uri callbackUri) async {
    final parameters = callbackUri.queryParameters;
    final error = parameters['error'];
    if (error != null) {
      throw SchwabAuthorizationException(
        'Schwab authorization was not completed ($error).',
      );
    }
    final code = parameters['code'];
    if (code == null || code.isEmpty) {
      throw ArgumentError(
        'The redirected URL does not contain a Schwab authorization code.',
      );
    }
    await exchangeAuthorizationCode(code, parameters['state']);
  }

  Future<void> exchangeAuthorizationCode(String code, String? state) async {
    final secrets = await _secrets();
    final appKey = secrets['appKey'];
    final appSecret = secrets['appSecret'];
    final redirectUri = secrets['redirectUri'];
    if (appKey == null || appSecret == null || redirectUri == null) {
      throw StateError('Schwab app credentials are not configured.');
    }
    if (state == null || state.isEmpty || state != secrets['oauthState']) {
      throw StateError(
        'OAuth state did not match; restart Schwab authorization.',
      );
    }
    secrets.remove('oauthState');
    final response = await _tokenRequest(secrets, {
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': redirectUri,
    });
    await _saveTokenResponse(secrets, response);
  }

  Future<void> startStreaming(List<String> symbols) async {
    if (symbols.isEmpty) throw ArgumentError('Add at least one symbol.');
    _symbols = symbols.map((symbol) => symbol.trim().toUpperCase()).toList();
    _stopping = false;
    await stopStreaming();
    _stopping = false;
    unawaited(_streamLoop());
  }

  /// Replaces the subscription with the union needed by independent runs,
  /// without dropping the authenticated socket or other runs' quote state.
  Future<void> updateStreamingSymbols(List<String> symbols) async {
    if (symbols.isEmpty) throw ArgumentError('Add at least one symbol.');
    final normalized = symbols
        .map((value) => value.trim().toUpperCase())
        .toSet();
    _symbols = normalized.toList();
    if (normalized.length == _subscribedSymbols.length &&
        normalized.containsAll(_subscribedSymbols)) {
      return;
    }
    final socket = _socket;
    final info = _activeStreamInfo;
    if (socket == null || info == null) return;
    final id = '${++_subscriptionRequestId}';
    final completion = Completer<void>();
    _subscriptionUpdates[id] = completion;
    try {
      socket.add(
        jsonEncode({
          'requests': [
            {
              'service': 'LEVELONE_EQUITIES',
              'command': 'SUBS',
              'requestid': id,
              'SchwabClientCustomerId': info['schwabClientCustomerId'],
              'SchwabClientCorrelId': info['schwabClientCorrelId'],
              'parameters': {
                'keys': normalized.join(','),
                'fields': LevelOneQuoteMerger.subscribedFields,
              },
            },
          ],
        }),
      );
      await completion.future.timeout(const Duration(seconds: 15));
      if (identical(socket, _socket)) _subscribedSymbols = normalized;
    } finally {
      _subscriptionUpdates.remove(id);
    }
  }

  Future<void> stopStreaming() async {
    _stopping = true;
    final socket = _socket;
    _socket = null;
    _activeStreamInfo = null;
    _subscribedSymbols.clear();
    if (socket != null) await socket.close();
  }

  Future<void> dispose() async {
    await stopStreaming();
    _http.close(force: true);
  }

  Future<bool> get isAuthorized async {
    final secrets = await _secrets();
    return secrets['refreshToken']?.isNotEmpty == true ||
        secrets['accessToken']?.isNotEmpty == true;
  }

  Future<({bool hasCredentials, bool authorized, String redirectUri})>
  get credentialStatus async {
    final secrets = await _secrets();
    return (
      hasCredentials:
          secrets['appKey']?.isNotEmpty == true &&
          secrets['appSecret']?.isNotEmpty == true,
      authorized:
          secrets['refreshToken']?.isNotEmpty == true ||
          secrets['accessToken']?.isNotEmpty == true,
      redirectUri: secrets['redirectUri'] ?? '',
    );
  }

  Future<bool> get hasCredentials async {
    final secrets = await _secrets();
    return secrets['appKey']?.isNotEmpty == true &&
        secrets['appSecret']?.isNotEmpty == true;
  }

  Future<void> removeCredentials() => storage.remove();

  Future<void> _streamLoop() async {
    var delay = const Duration(seconds: 1);
    while (!_stopping) {
      try {
        onState(FeedState.connecting, 'Opening authenticated Schwab stream.');
        _quoteMerger.reset();
        final secrets = await _secrets();
        final token = await _validAccessToken(secrets);
        final preference = await _getJson(
          '$apiBase/trader/v1/userPreference',
          token,
        );
        final streamInfo = _streamInfo(preference);
        final socket = await WebSocket.connect(
          streamInfo['streamerSocketUrl'] as String,
        );
        _socket = socket;
        final stream = StreamIterator<Object?>(socket);
        socket.add(
          jsonEncode({
            'requests': [
              {
                'service': 'ADMIN',
                'command': 'LOGIN',
                'requestid': '1',
                'SchwabClientCustomerId': streamInfo['schwabClientCustomerId'],
                'SchwabClientCorrelId': streamInfo['schwabClientCorrelId'],
                'parameters': {
                  'Authorization': token,
                  'SchwabClientChannel': streamInfo['schwabClientChannel'],
                  'SchwabClientFunctionId':
                      streamInfo['schwabClientFunctionId'],
                },
              },
            ],
          }),
        );
        await _awaitSuccessfulResponse(stream, 'ADMIN');
        final subscribedSymbols = _symbols.toSet();
        socket.add(
          jsonEncode({
            'requests': [
              {
                'service': 'LEVELONE_EQUITIES',
                'command': 'SUBS',
                'requestid': '2',
                'SchwabClientCustomerId': streamInfo['schwabClientCustomerId'],
                'SchwabClientCorrelId': streamInfo['schwabClientCorrelId'],
                'parameters': {
                  'keys': subscribedSymbols.join(','),
                  'fields': LevelOneQuoteMerger.subscribedFields,
                },
              },
            ],
          }),
        );
        await _awaitSuccessfulResponse(stream, 'LEVELONE_EQUITIES');
        _subscribedSymbols = subscribedSymbols;
        _activeStreamInfo = streamInfo;
        onState(FeedState.live, 'Authenticated streaming subscription active.');
        unawaited(_refreshStreamingSymbols());
        delay = const Duration(seconds: 1);
        try {
          while (!_stopping && await stream.moveNext()) {
            _handleStreamMessage(stream.current);
          }
        } finally {
          _activeStreamInfo = null;
          _subscribedSymbols.clear();
          for (final completion in _subscriptionUpdates.values) {
            if (!completion.isCompleted) {
              completion.completeError(
                StateError(
                  'Schwab disconnected before the subscription update.',
                ),
              );
            }
          }
          await stream.cancel();
        }
        if (!_stopping) {
          onState(FeedState.disconnected, 'Schwab stream ended; reconnecting.');
        }
      } on SchwabAuthorizationException catch (error) {
        onState(FeedState.reauthorizationRequired, error.message);
        return;
      } on SchwabAppAccessException catch (error) {
        // Retrying or reauthorizing cannot help until the Schwab app's API
        // products change, so stop and keep fills paused.
        onState(FeedState.disconnected, error.message);
        return;
      } catch (_) {
        if (!_stopping) {
          onState(
            FeedState.disconnected,
            'Schwab connection failed; retrying automatically.',
          );
        }
      } finally {
        final socket = _socket;
        _socket = null;
        if (socket != null && socket.readyState == WebSocket.open) {
          await socket.close();
        }
      }
      if (!_stopping) {
        await Future<void>.delayed(delay);
        delay = Duration(seconds: (delay.inSeconds * 2).clamp(1, 30));
      }
    }
  }

  Future<void> _refreshStreamingSymbols() async {
    try {
      await updateStreamingSymbols(_symbols);
    } catch (error) {
      if (!_stopping) {
        onState(
          FeedState.disconnected,
          'Schwab subscription update failed; reconnecting: $error',
        );
        await _socket?.close();
      }
    }
  }

  Future<void> _awaitSuccessfulResponse(
    StreamIterator<Object?> stream,
    String service,
  ) async {
    while (await stream.moveNext().timeout(const Duration(seconds: 15))) {
      final message = stream.current;
      if (message is! String) continue;
      final decoded = jsonDecode(message) as Map<String, dynamic>;
      final responses = decoded['response'] as List<dynamic>? ?? [];
      for (final response in responses) {
        final item = response as Map<String, dynamic>;
        if (item['service'] != service) continue;
        final content = item['content'] as Map<String, dynamic>? ?? {};
        if (content['code'] == 0) return;
        throw StateError('Schwab rejected the $service request.');
      }
    }
    throw StateError('Schwab stream closed before $service was ready.');
  }

  void _handleStreamMessage(Object? message) {
    if (message is! String) return;
    final decoded = jsonDecode(message) as Map<String, dynamic>;
    for (final response in decoded['response'] as List<dynamic>? ?? []) {
      final item = response as Map<String, dynamic>;
      final pending = _subscriptionUpdates[item['requestid']?.toString()];
      if (pending == null || pending.isCompleted) continue;
      final content = item['content'] as Map<String, dynamic>? ?? {};
      if (content['code'] == 0) {
        pending.complete();
      } else {
        pending.completeError(
          StateError('Schwab rejected subscription update.'),
        );
      }
    }
    for (final quote in _quoteMerger.apply(message)) {
      onQuote(quote);
    }
  }

  Future<String> _validAccessToken(Map<String, String> secrets) async {
    final expiry = int.tryParse(secrets['expiresAtMs'] ?? '') ?? 0;
    final token = secrets['accessToken'];
    if (token != null &&
        DateTime.now().millisecondsSinceEpoch + 60000 < expiry) {
      return token;
    }
    final refreshToken = secrets['refreshToken'];
    if (refreshToken == null || refreshToken.isEmpty) {
      throw SchwabAuthorizationException(
        'Schwab authorization is missing or expired. Reconnect in Settings.',
      );
    }
    try {
      final response = await _tokenRequest(secrets, {
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
      });
      await _saveTokenResponse(secrets, response);
      return secrets['accessToken']!;
    } on SchwabAuthorizationException {
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _tokenRequest(
    Map<String, String> secrets,
    Map<String, String> form,
  ) async {
    final key = secrets['appKey'];
    final secret = secrets['appSecret'];
    if (key == null || secret == null) {
      throw StateError('Schwab app credentials are not configured.');
    }
    final request = await _http.postUrl(Uri.parse(tokenEndpoint));
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Basic ${base64Encode(utf8.encode('$key:$secret'))}',
    );
    request.headers.contentType = ContentType(
      'application',
      'x-www-form-urlencoded',
    );
    request.write(
      form.entries
          .map(
            (entry) =>
                '${Uri.encodeComponent(entry.key)}=${Uri.encodeComponent(entry.value)}',
          )
          .join('&'),
    );
    final response = await request.close();
    final body = await utf8.decoder.bind(response).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 400 || response.statusCode == 401) {
        throw SchwabAuthorizationException(
          'Schwab rejected the OAuth request${_oauthErrorDetail(body)}. '
          'Check the Client ID, Client Secret, and callback URL, then '
          'reconnect in Settings.',
        );
      }
      throw StateError('Schwab OAuth request failed (${response.statusCode}).');
    }
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// Extracts Schwab's non-secret OAuth error code for display.
  static String _oauthErrorDetail(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final code = decoded['error']?.toString() ?? '';
        final description = decoded['error_description']?.toString() ?? '';
        final detail = [
          code,
          description,
        ].where((part) => part.isNotEmpty).join(': ');
        if (detail.isNotEmpty) {
          return ' (${detail.length > 160 ? detail.substring(0, 160) : detail})';
        }
      }
    } on FormatException {
      // Non-JSON bodies are not echoed because they may be large or HTML.
    }
    return '';
  }

  Future<void> _saveTokenResponse(
    Map<String, String> secrets,
    Map<String, dynamic> response,
  ) async {
    final access = response['access_token'] as String?;
    if (access == null) {
      throw StateError('Schwab OAuth response omitted a token.');
    }
    secrets['accessToken'] = access;
    final refresh = response['refresh_token'] as String?;
    if (refresh != null) secrets['refreshToken'] = refresh;
    final seconds = (response['expires_in'] as num?)?.toInt() ?? 1800;
    secrets['expiresAtMs'] =
        '${DateTime.now().millisecondsSinceEpoch + seconds * 1000}';
    await storage.save(secrets);
  }

  Future<Map<String, dynamic>> _getJson(String url, String token) async {
    final request = await _http.getUrl(Uri.parse(url));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close();
    if (response.statusCode == 401 || response.statusCode == 403) {
      final body = await utf8.decoder.bind(response).join();
      final appAccessProblem = traderApiAccessProblem(body);
      if (appAccessProblem != null) {
        throw SchwabAppAccessException(appAccessProblem);
      }
      throw SchwabAuthorizationException(
        'Schwab authorization is no longer valid. Reconnect in Settings.',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Schwab streaming preferences request failed.');
    }
    return jsonDecode(await utf8.decoder.bind(response).join())
        as Map<String, dynamic>;
  }

  /// Downloads regular-session one-minute bars for a historical replay.
  ///
  /// Uses Market Data `GET /marketdata/v1/pricehistory`. Schwab keeps only a
  /// limited window of minute history (roughly the last month) and returns
  /// split-adjusted prices. Results are kept in memory by the caller and are
  /// never written to disk.
  Future<List<MinuteBar>> fetchMinuteBars({
    required String symbol,
    required DateTime startUtc,
    required DateTime endUtc,
  }) async {
    final token = await _validAccessToken(await _secrets());
    final uri = Uri.parse('$apiBase/marketdata/v1/pricehistory').replace(
      queryParameters: {
        'symbol': symbol,
        'periodType': 'day',
        'frequencyType': 'minute',
        'frequency': '1',
        'startDate': '${startUtc.millisecondsSinceEpoch}',
        'endDate': '${endUtc.millisecondsSinceEpoch}',
        'needExtendedHoursData': 'false',
      },
    );
    final request = await _http.getUrl(uri);
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close();
    final body = await utf8.decoder.bind(response).join();
    if (response.statusCode == 401) {
      throw SchwabAuthorizationException(
        'Schwab authorization is no longer valid. Reconnect in Settings.',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        'Schwab price history for $symbol failed (${response.statusCode}).',
      );
    }
    return parsePriceHistory(symbol, body);
  }

  /// Parses a Schwab price-history body. `datetime` is the bar open time.
  static List<MinuteBar> parsePriceHistory(String symbol, String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) return const [];
    final rows = decoded['candles'];
    if (rows is! List) return const [];
    final bars = <MinuteBar>[];
    for (final row in rows) {
      if (row is! Map<String, dynamic>) continue;
      final time = row['datetime'];
      final values = [row['open'], row['high'], row['low'], row['close']];
      if (time is! num || values.any((value) => value is! num)) continue;
      bars.add(
        MinuteBar(
          symbol: symbol,
          openTime: DateTime.fromMillisecondsSinceEpoch(
            time.toInt(),
            isUtc: true,
          ),
          open: (row['open'] as num).toDouble(),
          high: (row['high'] as num).toDouble(),
          low: (row['low'] as num).toDouble(),
          close: (row['close'] as num).toDouble(),
          volume: (row['volume'] as num?)?.toDouble() ?? 0,
        ),
      );
    }
    bars.sort((a, b) => a.openTime.compareTo(b.openTime));
    return bars;
  }

  /// Returns a setup message when Schwab rejects a valid token because the
  /// developer app lacks the Trader API product. The streamer login details
  /// come only from `trader/v1/userPreference`, so streaming needs both the
  /// "Accounts and Trading Production" and "Market Data Production" products.
  static String? traderApiAccessProblem(String responseBody) {
    if (!responseBody.toLowerCase().contains('client not authorized')) {
      return null;
    }
    return 'Your Schwab login worked, but Schwab says this app is not '
        'authorized for the Accounts and Trading API, which provides the '
        'streaming login details. On developer.schwab.com, add the '
        '"Accounts and Trading Production" product to the app (alongside '
        '"Market Data Production"), wait for it to show Ready For Use, then '
        'reconnect Schwab in Settings.';
  }

  Map<String, dynamic> _streamInfo(Map<String, dynamic> preference) {
    final users = preference['streamerInfo'];
    if (users is List &&
        users.isNotEmpty &&
        users.first is Map<String, dynamic>) {
      return users.first as Map<String, dynamic>;
    }
    throw StateError('Schwab did not return streaming connection details.');
  }
}

/// Turns Schwab LEVELONE_EQUITIES stream messages into complete quotes.
///
/// Schwab sends only the fields that changed since the previous update, so
/// this keeps the latest value of each field per symbol and emits a quote once
/// bid, ask, last, volume, and an event time are all known. Field numbers come
/// from Schwab's Streamer API: 0 symbol, 1 bid, 2 ask, 3 last, 8 cumulative
/// session volume, 34 quote time (ms), 35 trade time (ms). Rows marked
/// `delayed: true` are passed on as not real-time so fills stay paused.
class LevelOneQuoteMerger {
  static const subscribedFields = '0,1,2,3,8,34,35';

  final Map<String, Map<String, Object?>> _latestFields = {};

  /// Clears merged state, e.g. after a reconnect, so no old value is reused.
  void reset() => _latestFields.clear();

  List<LiveQuote> apply(String message) {
    final decoded = jsonDecode(message);
    if (decoded is! Map<String, dynamic>) return const [];
    final quotes = <LiveQuote>[];
    for (final record in decoded['data'] as List<dynamic>? ?? const []) {
      if (record is! Map<String, dynamic>) continue;
      if (record['service'] != 'LEVELONE_EQUITIES') continue;
      final messageTime = _timestamp(record['timestamp']);
      for (final row in record['content'] as List<dynamic>? ?? const []) {
        if (row is! Map<String, dynamic>) continue;
        final symbol = (row['key'] ?? row['0'] ?? '').toString().toUpperCase();
        if (symbol.isEmpty) continue;
        final fields = _latestFields.putIfAbsent(symbol, () => {});
        for (final entry in row.entries) {
          if (entry.value != null) fields[entry.key] = entry.value;
        }
        final quoteTime = _timestamp(row['34']);
        final tradeTime = _timestamp(row['35']);
        final updateTimes = [quoteTime, tradeTime].whereType<DateTime>();
        final eventTime = updateTimes.isNotEmpty
            ? updateTimes.reduce((a, b) => a.isAfter(b) ? a : b)
            : messageTime;
        final bid = _number(fields['1']);
        final ask = _number(fields['2']);
        final last = _number(fields['3']);
        final volume = _number(fields['8']);
        if (bid == null ||
            ask == null ||
            last == null ||
            volume == null ||
            eventTime == null) {
          continue;
        }
        quotes.add(
          LiveQuote(
            symbol: symbol,
            time: eventTime,
            bid: bid,
            ask: ask,
            last: last,
            volume: volume,
            realTime: fields['delayed'] != true,
          ),
        );
      }
    }
    return quotes;
  }

  static double? _number(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  static DateTime? _timestamp(Object? value) {
    final milliseconds = value is num
        ? value.toInt()
        : value is String
        ? int.tryParse(value)
        : null;
    if (milliseconds == null || milliseconds <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
  }
}

/// Schwab accepted the token but the developer app lacks a required API
/// product. User action happens on developer.schwab.com, not in OAuth.
class SchwabAppAccessException implements Exception {
  const SchwabAppAccessException(this.message);

  final String message;

  @override
  String toString() => message;
}

class SchwabAuthorizationException implements Exception {
  const SchwabAuthorizationException(this.message);

  final String message;

  @override
  String toString() => message;
}
