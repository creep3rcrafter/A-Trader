import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:a_trade/market_data/alpaca_market_data_client.dart';
import 'package:a_trade/market_data/market_data.dart';
import 'package:a_trade/market_data/twelve_data_market_data_client.dart';

import 'assistant.dart';
import 'daily_indicator_service.dart';
import 'lan_data_policy.dart';
import 'research.dart';

class ATraderServer {
  ATraderServer({
    required this.bindAddress,
    required this.port,
    required this.selectedProvider,
    required this.marketDataClient,
    required this.providerStatuses,
    required this.assistantConfiguration,
    required this.assistantService,
    this.researchService,
    this.indicatorService,
    this.allowedOrigin,
    this.authenticationEnabled = false,
    this.authenticationPassword,
    this.staticRoot,
    this.lanDataPolicy,
    this.lanOrigins,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final String bindAddress;
  final int port;
  final MarketDataProvider selectedProvider;
  final MarketDataRepository? marketDataClient;
  final Map<String, Object?> providerStatuses;
  final AssistantConfiguration assistantConfiguration;
  final AssistantService? assistantService;
  final ResearchService? researchService;
  final DailyIndicatorService? indicatorService;
  final String? allowedOrigin;
  final bool authenticationEnabled;
  final String? authenticationPassword;
  final String? staticRoot;
  final LanDataPolicy? lanDataPolicy;
  final String? lanOrigins;
  final Set<String> _trustedLanOrigins = {};
  bool get _displayPermitted =>
      (lanDataPolicy ??
              LanDataPolicy(
                lanMode:
                    authenticationEnabled ||
                    !(InternetAddress.tryParse(bindAddress)?.isLoopback ??
                        false),
              ))
          .permits(selectedProvider);
  final DateTime Function() _clock;

  HttpServer? _server;
  String? _resolvedStaticRoot;
  final Map<String, DateTime> _sessions = {};
  final Map<String, _LoginThrottle> _loginThrottle = {};

  static const _sessionLifetime = Duration(hours: 24);
  static const _maximumSessions = 2048;
  static const _maximumLoginAddresses = 512;
  static const _loginFailureLimit = 5;
  static const _loginLockout = Duration(minutes: 15);
  static final Random _secureRandom = Random.secure();

  Uri get uri {
    final active = _server;
    if (active == null) throw StateError('Server has not started.');
    final host = active.address.type == InternetAddressType.IPv6
        ? '[${active.address.address}]'
        : active.address.address;
    return Uri.parse('http://$host:${active.port}');
  }

  Future<void> start() async {
    final address = InternetAddress.tryParse(bindAddress);
    if (address == null) {
      throw const FormatException(
        'A_TRADER_BIND_ADDRESS must be an IP address.',
      );
    }
    if (!address.isLoopback &&
        (!authenticationEnabled ||
            authenticationPassword == null ||
            !_isStrongPassword(authenticationPassword!) ||
            staticRoot == null)) {
      throw StateError(
        'Remote binds require enabled password authentication, a password '
        'of at least 12 characters, and a built web root.',
      );
    }
    if (authenticationEnabled &&
        (authenticationPassword == null ||
            !_isStrongPassword(authenticationPassword!))) {
      throw StateError(
        'Enabled web authentication requires a password of at least '
        '12 characters.',
      );
    }
    if (staticRoot != null) {
      final directory = Directory(staticRoot!);
      if (!await directory.exists()) {
        throw FileSystemException('Web build directory does not exist.');
      }
      _resolvedStaticRoot = await directory.resolveSymbolicLinks();
    }
    final configuredOrigins = _readLanOrigins();
    final interfaceAddresses =
        authenticationEnabled && configuredOrigins.isEmpty
        ? await NetworkInterface.list(
            includeLoopback: true,
            type: InternetAddressType.any,
          )
        : <NetworkInterface>[];
    _server = await HttpServer.bind(address, port);
    if (authenticationEnabled) {
      if (configuredOrigins.isNotEmpty) {
        if (configuredOrigins.any((origin) => origin.port != _server!.port)) {
          await close(force: true);
          throw const FormatException(
            'A_TRADER_LAN_ORIGINS must use the server listening port.',
          );
        }
        _trustedLanOrigins.addAll(
          configuredOrigins.map((origin) => origin.origin),
        );
      } else {
        final hosts = <String>{
          'localhost',
          '127.0.0.1',
          '::1',
          for (final interface in interfaceAddresses)
            for (final address in interface.addresses)
              if (address.address != '0.0.0.0' && address.address != '::')
                address.address,
        };
        _trustedLanOrigins.addAll(
          hosts.map(
            (host) =>
                Uri(scheme: 'http', host: host, port: _server!.port).origin,
          ),
        );
      }
    }
    _server!.idleTimeout = const Duration(seconds: 60);
    _server!.listen((request) => unawaited(_handleSafely(request)));
  }

  Future<void> close({bool force = false}) async {
    await _server?.close(force: force);
    _server = null;
  }

  Future<void> _handleSafely(HttpRequest request) async {
    try {
      await _handleRequest(request);
    } on _RequestBodyTooLarge {
      await _respond(request.response, HttpStatus.requestEntityTooLarge, {
        'error': 'Request body is too large.',
      });
    } on AssistantRequestException catch (error) {
      await _respond(request.response, error.statusCode, {
        'error': error.message,
      });
    } on AssistantModelException catch (error) {
      await _respond(request.response, HttpStatus.badGateway, {
        'error': error.message,
      });
    } on FormatException catch (error) {
      await _respond(request.response, HttpStatus.badRequest, {
        'error': error.message,
      });
    } on ArgumentError catch (error) {
      await _respond(request.response, HttpStatus.badRequest, {
        'error': error.message,
      });
    } on MarketDataException catch (error) {
      final statusCode = switch (error.statusCode) {
        HttpStatus.notFound => HttpStatus.notFound,
        HttpStatus.serviceUnavailable => HttpStatus.serviceUnavailable,
        HttpStatus.tooManyRequests => HttpStatus.tooManyRequests,
        _ => HttpStatus.badGateway,
      };
      await _respond(request.response, statusCode, {'error': error.message});
    } on SocketException {
      await _respond(request.response, HttpStatus.badGateway, {
        'error': 'Market-data service is unreachable.',
      });
    } on TimeoutException {
      await _respond(request.response, HttpStatus.gatewayTimeout, {
        'error': 'Market-data request timed out.',
      });
    } on HttpException {
      await _respond(request.response, HttpStatus.badGateway, {
        'error': 'Market-data HTTP request failed.',
      });
    } on FileSystemException {
      await _respond(request.response, HttpStatus.serviceUnavailable, {
        'error': 'Local market-data storage is unavailable.',
      });
    } catch (_) {
      await _respond(request.response, HttpStatus.internalServerError, {
        'error': 'The local service could not complete the request.',
      });
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (authenticationEnabled && _trustedRequestOrigin(request) == null) {
      await _respond(request.response, HttpStatus.forbidden, {
        'error': 'Host is not allowed.',
      });
      return;
    }
    if (!_setCorsHeaders(request)) {
      await _respond(request.response, HttpStatus.forbidden, {
        'error': 'Origin is not allowed.',
      });
      return;
    }
    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      return;
    }

    final path = request.uri.path;
    if (authenticationEnabled && path == '/auth/login') {
      await _login(request);
      return;
    }
    if (authenticationEnabled &&
        request.method == 'POST' &&
        !_isSameOriginRequest(request)) {
      await _respond(request.response, HttpStatus.forbidden, {
        'error': 'A matching Origin is required.',
      });
      return;
    }
    if (authenticationEnabled && path == '/auth/logout') {
      if (request.method != 'POST') {
        await _methodNotAllowed(request.response, 'POST');
        return;
      }
      _sessions.remove(_sessionToken(request));
      request.response.headers.add(
        HttpHeaders.setCookieHeader,
        'a_trader_session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0',
      );
      await _respond(request.response, HttpStatus.ok, {'status': 'loggedOut'});
      return;
    }
    if (authenticationEnabled && !_hasValidSession(request)) {
      if (_isStaticRequest(path)) {
        if (path == '/' || _acceptsHtml(request)) {
          await _respondRaw(
            request.response,
            HttpStatus.ok,
            _loginPage,
            ContentType.html,
          );
        } else {
          await _respond(request.response, HttpStatus.unauthorized, {
            'error': 'Authentication is required.',
          });
        }
      } else {
        await _respond(request.response, HttpStatus.unauthorized, {
          'error': 'Authentication is required.',
        });
      }
      return;
    }

    if (path == '/health') {
      if (request.method != 'GET') {
        await _methodNotAllowed(request.response, 'GET');
        return;
      }
      await _respond(request.response, HttpStatus.ok, {
        'status': 'ok',
        'provider': selectedProvider.name,
        'activeProvider': selectedProvider.name,
        'feed': _healthFeed(selectedProvider),
        'configured': marketDataClient != null && _displayPermitted,
        'providers': {
          ...providerStatuses,
          if (researchService?.tools.webSearch case final search?)
            'duckDuckGo': search.health,
          if (!_displayPermitted)
            selectedProvider.name: {
              if (providerStatuses[selectedProvider.name]
                  case final Map<String, Object?> status)
                ...status,
              'enabled': false,
            },
          ...(_assistantHealth['providers']! as Map<String, Object?>),
        },
        if (marketDataClient == null || !_displayPermitted)
          'disabledReason': !_displayPermitted
              ? 'Provider LAN display rights are not confirmed.'
              : 'Credentials are missing or provider data-use terms are not confirmed.',
        'coverage': _coverage(selectedProvider),
        'assistant': _assistantHealth,
      });
      return;
    }

    if (path == '/api/v1/assistant/explain' ||
        path == '/api/v1/assistant/research') {
      final research = path.endsWith('/research');
      if (request.method != 'POST') {
        await _methodNotAllowed(request.response, 'POST');
        return;
      }
      if (!_displayPermitted) {
        throw const AssistantRequestException(
          HttpStatus.serviceUnavailable,
          'Provider LAN display rights are not confirmed.',
        );
      }
      final body = await _readJsonBody(
        request,
        maximumBytes: assistantConfiguration.maximumInputCharacters * 4 + 256,
      );
      final allowedKeys = {
        'symbol',
        'prompt',
        if (research) ...['holdingDays', 'lookbackDays'],
      };
      if (body.keys.any((key) => !allowedKeys.contains(key))) {
        throw const FormatException('Unsupported assistant request field.');
      }
      final rawSymbol = body['symbol'];
      final prompt = body['prompt'];
      if (rawSymbol is! String || prompt is! String) {
        throw const FormatException('symbol and prompt must both be strings.');
      }
      final symbol = rawSymbol.trim().toUpperCase();
      if (!RegExp(r'^[A-Z0-9.-]{1,15}$').hasMatch(symbol)) {
        throw const FormatException('symbol must be a valid ticker.');
      }
      if (prompt.length > assistantConfiguration.maximumInputCharacters) {
        throw const FormatException(
          'prompt exceeds the configured input limit.',
        );
      }
      if (research) {
        final holdingDays = body['holdingDays'];
        final lookbackDays = body['lookbackDays'];
        if (holdingDays is! int || lookbackDays is! int) {
          throw const FormatException(
            'holdingDays and lookbackDays must be integers.',
          );
        }
        final service = researchService;
        if (service == null) {
          throw const AssistantRequestException(
            HttpStatus.serviceUnavailable,
            'Local research is disabled. Configure LM Studio and processing permissions.',
          );
        }
        await _respond(
          request.response,
          HttpStatus.ok,
          await service.research(
            symbol: symbol,
            prompt: prompt,
            holdingDays: holdingDays,
            lookbackDays: lookbackDays,
          ),
        );
        return;
      }
      final service = assistantService;
      if (service == null) {
        throw const AssistantRequestException(
          HttpStatus.serviceUnavailable,
          'Assistant explanations are disabled by configuration.',
        );
      }
      final response = await service.explain(symbol: symbol, prompt: prompt);
      await _respond(request.response, HttpStatus.ok, response);
      return;
    }

    if (path == '/api/v1/market-data/quote') {
      if (request.method != 'GET') {
        await _methodNotAllowed(request.response, 'GET');
        return;
      }
      final client = marketDataClient;
      if (client == null || !_displayPermitted) {
        await _providerNotConfigured(request.response, selectedProvider);
        return;
      }
      final symbol = _requiredQuery(request.uri, 'symbol');
      final quote = await client.latestQuote(symbol);
      if (quote == null) {
        await _respond(request.response, HttpStatus.notFound, {
          'error': 'No quote is available for this symbol.',
        });
        return;
      }
      if (selectedProvider == MarketDataProvider.schwab &&
          (quote.symbol != symbol.trim().toUpperCase() ||
              quote.provider != selectedProvider ||
              quote.feed != MarketDataFeed.schwabEquity ||
              quote.sourceTimestamp.isAfter(quote.retrievedAt) ||
              quote.retrievedAt.isAfter(_clock().toUtc()))) {
        throw const MarketDataException('Invalid Schwab quote provenance.');
      }
      await _respond(request.response, HttpStatus.ok, {
        'data': quote.toJson(
          now: DateTime.now().toUtc(),
          maximumAge: const Duration(minutes: 1),
        ),
        'provider': quote.provider.name,
        'feed': quote.feed.name,
        'coverage': _coverage(selectedProvider),
        ..._clientMetadata(client),
      });
      return;
    }

    if (path == '/api/v1/market-data/bars') {
      if (request.method != 'GET') {
        await _methodNotAllowed(request.response, 'GET');
        return;
      }
      final client = marketDataClient;
      if (client == null || !_displayPermitted) {
        await _providerNotConfigured(request.response, selectedProvider);
        return;
      }
      final symbol = _requiredQuery(request.uri, 'symbol');
      final start = _requiredDate(request.uri, 'start');
      final end = _requiredDate(request.uri, 'end');
      final adjustment = _readAdjustment(
        request.uri.queryParameters['adjustment'],
      );
      final bars = await client.dailyBars(
        symbol,
        start: start,
        end: end,
        adjustment: adjustment,
      );
      if (selectedProvider == MarketDataProvider.schwab &&
          (bars.length > 120 ||
              bars.any(
                (bar) =>
                    bar.symbol != symbol.trim().toUpperCase() ||
                    bar.provider != selectedProvider ||
                    bar.feed != MarketDataFeed.schwabEquity ||
                    bar.adjustment != PriceAdjustment.unknown,
              ))) {
        throw const MarketDataException(
          'Invalid Schwab daily history provenance.',
        );
      }
      await _respond(request.response, HttpStatus.ok, {
        'data': [for (final bar in bars) bar.toJson()],
        'provider': selectedProvider.name,
        'feed': _barsFeed(selectedProvider),
        'coverage': _coverage(selectedProvider),
        'count': bars.length,
        ..._clientMetadata(client),
      });
      return;
    }

    if (path == '/api/v1/market-data/indicators') {
      if (request.method != 'GET') {
        await _methodNotAllowed(request.response, 'GET');
        return;
      }
      final client = marketDataClient;
      if (client == null || !_displayPermitted) {
        await _providerNotConfigured(request.response, selectedProvider);
        return;
      }
      final query = request.uri.queryParametersAll;
      final symbols = query['symbol'];
      if (query.length != 1 || symbols == null || symbols.length != 1) {
        throw const FormatException(
          'Only one normalized symbol query parameter is supported.',
        );
      }
      final symbol = symbols.single;
      if (symbol != symbol.trim().toUpperCase() ||
          !RegExp(r'^[A-Z0-9.-]{1,15}$').hasMatch(symbol)) {
        throw const FormatException(
          'symbol must be a normalized uppercase ticker.',
        );
      }
      final service =
          indicatorService ??
          DailyIndicatorService(
            marketData: client,
            provider: selectedProvider,
            clock: _clock,
          );
      await _respond(
        request.response,
        HttpStatus.ok,
        await service.analyze(symbol: symbol),
      );
      return;
    }

    if (_isStaticRequest(path)) {
      await _serveStatic(request);
      return;
    }
    await _respond(request.response, HttpStatus.notFound, {
      'error': 'Route not found.',
    });
  }

  Future<void> _login(HttpRequest request) async {
    if (request.method != 'POST') {
      await _methodNotAllowed(request.response, 'POST');
      return;
    }
    if (!_isSameOriginRequest(request)) {
      await _respond(request.response, HttpStatus.forbidden, {
        'error': 'Origin is not allowed.',
      });
      return;
    }
    final address = request.connectionInfo?.remoteAddress.address ?? 'unknown';
    final now = _clock();
    final throttle = _loginThrottle[address];
    final blockedUntil = throttle?.blockedUntil;
    if (blockedUntil != null && blockedUntil.isAfter(now)) {
      request.response.headers.set(
        HttpHeaders.retryAfterHeader,
        blockedUntil.difference(now).inSeconds.toString(),
      );
      await _respond(request.response, HttpStatus.tooManyRequests, {
        'error': 'Too many login attempts. Try again later.',
      });
      return;
    }
    final bytes = await _readBody(request, maximumBytes: 2048);
    final credentials = _decodeLoginBody(request, bytes);
    final password = credentials['password'];
    if (password == null ||
        !_constantTimeEquals(password, authenticationPassword ?? '')) {
      final previousFailures =
          throttle != null && throttle.windowExpiresAt.isAfter(now)
          ? throttle.failures
          : 0;
      final failures = previousFailures + 1;
      _loginThrottle[address] = _LoginThrottle(
        failures,
        now.add(_loginLockout),
        failures >= _loginFailureLimit ? now.add(_loginLockout) : null,
      );
      _trimLoginThrottle();
      if (failures >= _loginFailureLimit) {
        await _respond(request.response, HttpStatus.tooManyRequests, {
          'error': 'Too many login attempts. Try again later.',
        });
      } else if (_isJsonRequest(request)) {
        await _respond(request.response, HttpStatus.unauthorized, {
          'error': 'Invalid password.',
        });
      } else {
        await _respondRaw(
          request.response,
          HttpStatus.unauthorized,
          _loginPage,
          ContentType.html,
        );
      }
      return;
    }

    _loginThrottle.remove(address);
    _trimSessions();
    final token = _newSessionToken();
    _sessions[token] = now.add(_sessionLifetime);
    request.response.headers.add(
      HttpHeaders.setCookieHeader,
      'a_trader_session=$token; Path=/; HttpOnly; SameSite=Strict; '
      'Max-Age=${_sessionLifetime.inSeconds}',
    );
    if (_isJsonRequest(request)) {
      await _respond(request.response, HttpStatus.ok, {
        'status': 'authenticated',
        'expiresInSeconds': _sessionLifetime.inSeconds,
      });
    } else {
      request.response
        ..statusCode = HttpStatus.seeOther
        ..headers.set(HttpHeaders.locationHeader, '/');
      await request.response.close();
    }
  }

  Future<void> _serveStatic(HttpRequest request) async {
    final root = _resolvedStaticRoot;
    if (root == null) {
      await _respond(request.response, HttpStatus.notFound, {
        'error': 'Static web hosting is not configured.',
      });
      return;
    }
    final path = request.uri.path;
    if (_unsafePath(path)) {
      await _respond(request.response, HttpStatus.notFound, {
        'error': 'File not found.',
      });
      return;
    }
    final relative = path == '/' ? 'index.html' : path.substring(1);
    final candidate = File(
      '$root${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}',
    );
    File file;
    try {
      final resolved = await candidate.resolveSymbolicLinks();
      if (!_isUnderRoot(resolved, root)) {
        await _respond(request.response, HttpStatus.notFound, {
          'error': 'File not found.',
        });
        return;
      }
      file = File(resolved);
      if (await FileSystemEntity.type(resolved) ==
          FileSystemEntityType.directory) {
        file = File('$resolved${Platform.pathSeparator}index.html');
      }
    } on FileSystemException {
      if (!_acceptsHtml(request) || path.contains('.')) {
        await _respond(request.response, HttpStatus.notFound, {
          'error': 'File not found.',
        });
        return;
      }
      file = File('$root${Platform.pathSeparator}index.html');
    }
    if (!await file.exists()) {
      await _respond(request.response, HttpStatus.notFound, {
        'error': 'File not found.',
      });
      return;
    }
    final resolvedFile = await file.resolveSymbolicLinks();
    if (!_isUnderRoot(resolvedFile, root)) {
      await _respond(request.response, HttpStatus.notFound, {
        'error': 'File not found.',
      });
      return;
    }
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = _contentType(file.path)
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
      ..headers.set('X-Content-Type-Options', 'nosniff')
      ..headers.set('X-Frame-Options', 'DENY')
      ..headers.set('Referrer-Policy', 'no-referrer');
    await request.response.addStream(File(resolvedFile).openRead());
    await request.response.close();
  }

  Future<Map<String, Object?>> _readJsonBody(
    HttpRequest request, {
    required int maximumBytes,
  }) async {
    final bytes = await _readBody(request, maximumBytes: maximumBytes);
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Request body must be a JSON object.');
    }
    return decoded;
  }

  Future<List<int>> _readBody(
    HttpRequest request, {
    required int maximumBytes,
  }) async {
    if (request.contentLength > maximumBytes) {
      throw const _RequestBodyTooLarge();
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request) {
      if (builder.length + chunk.length > maximumBytes) {
        throw const _RequestBodyTooLarge();
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Map<String, String> _decodeLoginBody(HttpRequest request, List<int> bytes) {
    if (_isJsonRequest(request)) {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map<String, dynamic> &&
          decoded.keys.every((key) => key == 'password') &&
          decoded['password'] is String) {
        return {'password': decoded['password'] as String};
      }
      return const {};
    }
    if (request.headers.contentType?.mimeType !=
        'application/x-www-form-urlencoded') {
      return const {};
    }
    final values = Uri.splitQueryString(utf8.decode(bytes));
    if (values.keys.any((key) => key != 'password')) return const {};
    return values;
  }

  bool _setCorsHeaders(HttpRequest request) {
    final origin = request.headers.value('origin');
    if (origin == null) return true;
    if (authenticationEnabled) return _isSameOriginRequest(request);
    if (allowedOrigin != null && origin == allowedOrigin) {
      request.response.headers
        ..set(HttpHeaders.accessControlAllowOriginHeader, allowedOrigin!)
        ..set(HttpHeaders.accessControlAllowMethodsHeader, 'GET, POST, OPTIONS')
        ..set(HttpHeaders.accessControlAllowHeadersHeader, 'Content-Type')
        ..set(HttpHeaders.varyHeader, 'Origin');
      return true;
    }
    return false;
  }

  bool _isSameOriginRequest(HttpRequest request) {
    final origin = request.headers.value('origin');
    final trustedOrigin = _trustedRequestOrigin(request);
    return origin != null && trustedOrigin != null && origin == trustedOrigin;
  }

  String? _trustedRequestOrigin(HttpRequest request) {
    final hostHeaders = request.headers[HttpHeaders.hostHeader];
    if (hostHeaders == null || hostHeaders.length != 1) return null;
    final authority = hostHeaders.single;
    final uri = Uri.tryParse('http://$authority');
    if (uri == null ||
        uri.userInfo.isNotEmpty ||
        uri.path.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        authority != uri.authority ||
        !_trustedLanOrigins.contains(uri.origin)) {
      return null;
    }
    return uri.origin;
  }

  List<Uri> _readLanOrigins() {
    if (!authenticationEnabled || lanOrigins == null || lanOrigins!.isEmpty) {
      return const [];
    }
    final values = lanOrigins!.split(',');
    if (values.length > 32) {
      throw const FormatException('Too many configured LAN origins.');
    }
    return values.map((value) {
      final origin = value.trim();
      final uri = Uri.tryParse(origin);
      if (uri == null ||
          uri.scheme != 'http' ||
          !uri.hasAuthority ||
          uri.userInfo.isNotEmpty ||
          origin != uri.origin ||
          uri.host.contains('*')) {
        throw const FormatException(
          'A_TRADER_LAN_ORIGINS must contain exact HTTP origins separated by commas.',
        );
      }
      return uri;
    }).toList();
  }

  bool _hasValidSession(HttpRequest request) {
    final token = _sessionToken(request);
    if (token == null) return false;
    final expiry = _sessions[token];
    if (expiry == null) return false;
    if (!expiry.isAfter(_clock())) {
      _sessions.remove(token);
      return false;
    }
    return true;
  }

  String? _sessionToken(HttpRequest request) {
    final rawCookie = request.headers.value(HttpHeaders.cookieHeader);
    if (rawCookie == null) return null;
    for (final cookie in rawCookie.split(';')) {
      final pair = cookie.trim().split('=');
      if (pair.length == 2 && pair[0] == 'a_trader_session') {
        return pair[1];
      }
    }
    return null;
  }

  void _trimSessions() {
    final now = _clock();
    _sessions.removeWhere((_, expiresAt) => !expiresAt.isAfter(now));
    while (_sessions.length >= _maximumSessions) {
      _sessions.remove(_sessions.keys.first);
    }
  }

  void _trimLoginThrottle() {
    if (_loginThrottle.length <= _maximumLoginAddresses) return;
    final now = _clock();
    _loginThrottle.removeWhere(
      (_, attempt) => attempt.windowExpiresAt.isBefore(now),
    );
    while (_loginThrottle.length > _maximumLoginAddresses) {
      _loginThrottle.remove(_loginThrottle.keys.first);
    }
  }

  String _newSessionToken() {
    final bytes = List<int>.generate(32, (_) => _secureRandom.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  bool _isStaticRequest(String path) =>
      path == '/' ||
      (path != '/health' &&
          !path.startsWith('/api/') &&
          !path.startsWith('/auth/'));

  bool _isJsonRequest(HttpRequest request) =>
      request.headers.contentType?.mimeType == ContentType.json.mimeType;

  bool _acceptsHtml(HttpRequest request) =>
      request.headers.value(HttpHeaders.acceptHeader)?.contains('text/html') ??
      false;

  bool _unsafePath(String path) {
    if (path.contains('\\') || path.contains('\u0000')) return true;
    return path.split('/').any((segment) => segment == '..' || segment == '.');
  }

  bool _isUnderRoot(String path, String root) {
    final normalizedRoot = root.endsWith(Platform.pathSeparator)
        ? root
        : '$root${Platform.pathSeparator}';
    return path == root || path.startsWith(normalizedRoot);
  }

  Map<String, Object?> get _assistantHealth {
    final configuredHealth = assistantConfiguration.health;
    final actualEnabled =
        assistantConfiguration.enabled &&
        _displayPermitted &&
        marketDataClient != null &&
        assistantService != null;
    final statuses = configuredHealth['providers']! as Map<String, Object?>;
    final assistantProviders = <String, Object?>{
      for (final entry in statuses.entries)
        entry.key: {
          ...(entry.value as Map<String, Object?>),
          'enabled':
              actualEnabled &&
              (entry.value as Map<String, Object?>)['selected'] == true,
        },
    };
    return {
      ...configuredHealth,
      'enabled': actualEnabled,
      'marketDataConfigured': marketDataClient != null,
      'providers': assistantProviders,
    };
  }

  ContentType _contentType(String path) {
    final extension = path.split('.').last.toLowerCase();
    return switch (extension) {
      'html' => ContentType.html,
      'js' || 'mjs' => ContentType('text', 'javascript', charset: 'utf-8'),
      'css' => ContentType('text', 'css', charset: 'utf-8'),
      'json' || 'map' => ContentType.json,
      'svg' => ContentType('image', 'svg+xml', charset: 'utf-8'),
      'png' => ContentType('image', 'png'),
      'jpg' || 'jpeg' => ContentType('image', 'jpeg'),
      'ico' => ContentType('image', 'vnd.microsoft.icon'),
      'wasm' => ContentType('application', 'wasm'),
      'woff' => ContentType('font', 'woff'),
      'woff2' => ContentType('font', 'woff2'),
      _ => ContentType.binary,
    };
  }

  Future<void> _respond(
    HttpResponse response,
    int statusCode,
    Map<String, Object?> body,
  ) async {
    response
      ..statusCode = statusCode
      ..headers.contentType = ContentType.json
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
      ..headers.set('X-Content-Type-Options', 'nosniff')
      ..write(jsonEncode(body));
    await response.close();
  }

  Future<void> _respondRaw(
    HttpResponse response,
    int statusCode,
    String body,
    ContentType contentType,
  ) async {
    response
      ..statusCode = statusCode
      ..headers.contentType = contentType
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
      ..headers.set('X-Content-Type-Options', 'nosniff')
      ..write(body);
    await response.close();
  }

  Future<void> _methodNotAllowed(HttpResponse response, String method) =>
      _respond(response, HttpStatus.methodNotAllowed, {
        'error': 'Only $method requests are supported.',
      });

  Future<void> _providerNotConfigured(
    HttpResponse response,
    MarketDataProvider provider,
  ) => _respond(response, HttpStatus.serviceUnavailable, {
    'error':
        '${provider.name} is not configured or its terms are not confirmed.',
  });

  String _requiredQuery(Uri uri, String name) {
    final value = uri.queryParameters[name];
    if (value == null || value.trim().isEmpty) {
      throw FormatException('Missing required query parameter: $name');
    }
    return value;
  }

  DateTime _requiredDate(Uri uri, String name) {
    final value = _requiredQuery(uri, name);
    final parsed = DateTime.tryParse(value);
    if (parsed == null) {
      throw FormatException('$name must be an ISO-8601 date.');
    }
    return parsed;
  }

  PriceAdjustment _readAdjustment(String? value) {
    if (value == null || value == 'raw') return PriceAdjustment.raw;
    return switch (value) {
      'split' => PriceAdjustment.split,
      'dividend' => PriceAdjustment.dividend,
      'all' => PriceAdjustment.all,
      _ => throw const FormatException(
        'adjustment must be raw, split, dividend, or all.',
      ),
    };
  }

  Map<String, Object?> _clientMetadata(MarketDataRepository client) {
    return switch (client) {
      AlpacaMarketDataClient alpaca => {
        if (alpaca.lastRateLimit case final rateLimit?)
          'rateLimit': rateLimit.toJson(),
      },
      TwelveDataMarketDataClient twelveData => {
        if (twelveData.lastCreditUsage case final credits?)
          'creditUsage': credits.toJson(),
      },
      _ => const {},
    };
  }

  String _healthFeed(MarketDataProvider provider) => switch (provider) {
    MarketDataProvider.alpaca => MarketDataFeed.iex.name,
    MarketDataProvider.twelveData => 'partial_us_equity_unverified',
    MarketDataProvider.schwab => MarketDataFeed.schwabEquity.name,
  };

  String _barsFeed(MarketDataProvider provider) => switch (provider) {
    MarketDataProvider.alpaca => MarketDataFeed.iex.name,
    MarketDataProvider.twelveData => MarketDataFeed.endOfDay.name,
    MarketDataProvider.schwab => MarketDataFeed.schwabEquity.name,
  };

  String _coverage(MarketDataProvider provider) => switch (provider) {
    MarketDataProvider.alpaca =>
      'Supported US stocks and ETFs only; IEX single-exchange coverage; OTC unavailable.',
    MarketDataProvider.twelveData =>
      'US listed equity realtime is partial (about 5% market volume), not consolidated; daily history has complete US volume after midnight ET on the next trading day; OTC unavailable.',
    MarketDataProvider.schwab =>
      'Schwab equity REST; realtime/quoteType are source metadata, not verified SIP entitlement. Daily adjustment/timezone unknown; indicators unavailable.',
  };
}

class _LoginThrottle {
  const _LoginThrottle(this.failures, this.windowExpiresAt, this.blockedUntil);
  final int failures;
  final DateTime windowExpiresAt;
  final DateTime? blockedUntil;
}

class _RequestBodyTooLarge implements Exception {
  const _RequestBodyTooLarge();
}

bool _constantTimeEquals(String candidate, String expected) {
  final left = utf8.encode(candidate);
  final right = utf8.encode(expected);
  var difference = left.length ^ right.length;
  final length = max(left.length, right.length);
  for (var index = 0; index < length; index++) {
    difference |=
        (index < left.length ? left[index] : 0) ^
        (index < right.length ? right[index] : 0);
  }
  return difference == 0;
}

bool _isStrongPassword(String password) {
  return password.length >= 12;
}

const _loginPage = '''<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>A-Trader sign in</title>
<style>body{font:16px system-ui;max-width:26rem;margin:12vh auto;padding:1.5rem;background:#f4f7fb;color:#182234}form{display:grid;gap:1rem;background:white;padding:2rem;border-radius:1rem}input,button{font:inherit;padding:.8rem}button{background:#174ea6;color:white;border:0;border-radius:.4rem}</style>
<h1>A-Trader</h1><form method="post" action="/auth/login">
<label for="password">LAN access password</label>
<input id="password" name="password" type="password" autocomplete="current-password" required autofocus>
<button type="submit">Sign in</button>
</form></html>''';
