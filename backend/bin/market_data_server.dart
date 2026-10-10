import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:a_trade/market_data/alpaca_market_data_client.dart';
import 'package:a_trade/market_data/market_data.dart';

Future<void> main() async {
  final port = _readPort(Platform.environment['A_TRADER_PORT']);
  final keyId = Platform.environment['ALPACA_API_KEY_ID'];
  final secret = Platform.environment['ALPACA_API_SECRET_KEY'];
  final schwabCredentialsPresent =
      _isConfigured('SCHWAB_CLIENT_ID') &&
      _isConfigured('SCHWAB_CLIENT_SECRET');
  final alphaVantageCredentialsPresent = _isConfigured('ALPHA_VANTAGE_API_KEY');
  final brightDataCredentialsPresent = _isConfigured('BRIGHT_DATA_API_TOKEN');
  final openAiCredentialsPresent = _isConfigured('OPENAI_API_KEY');
  final termsConfirmed =
      Platform.environment['ALPACA_MARKET_DATA_TERMS_CONFIRMED'] == 'true';
  final credentialsAvailable =
      keyId != null &&
      keyId.trim().isNotEmpty &&
      secret != null &&
      secret.trim().isNotEmpty;
  final client = credentialsAvailable && termsConfirmed
      ? AlpacaMarketDataClient(
          apiKeyId: keyId,
          apiSecretKey: secret,
          allowCaching:
              Platform.environment['ALPACA_DATA_CACHING_PERMITTED'] == 'true',
        )
      : null;
  final allowedOrigin = Platform.environment['A_TRADER_ALLOWED_ORIGIN'];
  final providerStatuses = <String, Object?>{
    'alpaca': {
      'credentialsPresent': credentialsAvailable,
      'enabled': client != null,
      'integrationImplemented': true,
      'termsConfirmed': termsConfirmed,
    },
    'schwab': {
      'credentialsPresent': schwabCredentialsPresent,
      'enabled': false,
      'integrationImplemented': false,
    },
    'alphaVantage': {
      'credentialsPresent': alphaVantageCredentialsPresent,
      'enabled': false,
      'integrationImplemented': false,
    },
    'brightData': {
      'credentialsPresent': brightDataCredentialsPresent,
      'enabled': false,
      'integrationImplemented': false,
    },
    'openAi': {
      'credentialsPresent': openAiCredentialsPresent,
      'enabled': false,
      'integrationImplemented': false,
    },
    'secEdgar': {
      'credentialsPresent': false,
      'enabled': false,
      'integrationImplemented': false,
      'requiresApiKey': false,
    },
  };
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);

  stdout.writeln(
    'A-Trader market-data service listening on http://127.0.0.1:$port '
    '(Alpaca IEX ${client == null ? 'disabled' : 'enabled'}).',
  );
  if (!termsConfirmed) {
    stdout.writeln(
      'Provider calls are disabled until the Alpaca market-data terms are reviewed.',
    );
  }
  if (allowedOrigin == null || allowedOrigin.isEmpty) {
    stdout.writeln(
      'Browser requests are disabled until A_TRADER_ALLOWED_ORIGIN is set.',
    );
  }

  await for (final request in server) {
    await _handleRequest(request, client, allowedOrigin, providerStatuses);
  }
}

Future<void> _handleRequest(
  HttpRequest request,
  AlpacaMarketDataClient? client,
  String? allowedOrigin,
  Map<String, Object?> providerStatuses,
) async {
  if (!_setCorsHeaders(request, allowedOrigin)) {
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
  if (request.method != 'GET') {
    await _respond(request.response, HttpStatus.methodNotAllowed, {
      'error': 'Only GET requests are supported.',
    });
    return;
  }

  try {
    if (request.uri.path == '/health') {
      await _respond(request.response, HttpStatus.ok, {
        'status': 'ok',
        'provider': 'alpaca',
        'feed': 'iex',
        'configured': client != null,
        'providers': providerStatuses,
        if (client == null)
          'disabledReason':
              'Credentials are missing or data-use terms are not confirmed.',
        'coverage': 'Supported US stocks and ETFs only; OTC is unavailable.',
      });
      return;
    }

    if (request.uri.path == '/api/v1/market-data/quote') {
      if (client == null) {
        await _providerNotConfigured(request.response);
        return;
      }
      final symbol = _requiredQuery(request.uri, 'symbol');
      final quote = await client.latestQuote(symbol);
      if (quote == null) {
        await _respond(request.response, HttpStatus.notFound, {
          'error': 'No IEX quote or trade is available for this symbol.',
        });
        return;
      }
      await _respond(request.response, HttpStatus.ok, {
        'data': quote.toJson(
          now: DateTime.now().toUtc(),
          maximumAge: const Duration(minutes: 1),
        ),
        if (client.lastRateLimit case final rateLimit?)
          'rateLimit': rateLimit.toJson(),
      });
      return;
    }

    if (request.uri.path == '/api/v1/market-data/bars') {
      if (client == null) {
        await _providerNotConfigured(request.response);
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
      await _respond(request.response, HttpStatus.ok, {
        'data': [for (final bar in bars) bar.toJson()],
        'provider': MarketDataProvider.alpaca.name,
        'feed': MarketDataFeed.iex.name,
        'count': bars.length,
        if (client.lastRateLimit case final rateLimit?)
          'rateLimit': rateLimit.toJson(),
      });
      return;
    }

    await _respond(request.response, HttpStatus.notFound, {
      'error': 'Route not found.',
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
  }
}

bool _isConfigured(String name) {
  final value = Platform.environment[name];
  return value != null && value.trim().isNotEmpty;
}

bool _setCorsHeaders(HttpRequest request, String? allowedOrigin) {
  final origin = request.headers.value('origin');
  if (origin == null) return true;
  if (allowedOrigin == null || origin != allowedOrigin) return false;

  request.response.headers
    ..set(HttpHeaders.accessControlAllowOriginHeader, allowedOrigin)
    ..set(HttpHeaders.accessControlAllowMethodsHeader, 'GET, OPTIONS')
    ..set(HttpHeaders.varyHeader, 'Origin');
  return true;
}

Future<void> _providerNotConfigured(
  HttpResponse response,
) => _respond(response, HttpStatus.serviceUnavailable, {
  'error':
      'Alpaca is not configured. Set server-side API credentials before requesting data.',
});

Future<void> _respond(
  HttpResponse response,
  int statusCode,
  Map<String, Object?> body,
) async {
  response
    ..statusCode = statusCode
    ..headers.contentType = ContentType.json
    ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
    ..write(jsonEncode(body));
  await response.close();
}

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
  if (parsed == null) throw FormatException('$name must be an ISO-8601 date.');
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

int _readPort(String? value) {
  if (value == null || value.isEmpty) return 8765;
  final port = int.tryParse(value);
  if (port == null || port < 1024 || port > 65535) {
    throw const FormatException(
      'A_TRADER_PORT must be between 1024 and 65535.',
    );
  }
  return port;
}
