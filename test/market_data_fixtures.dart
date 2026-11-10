import 'dart:convert';

import 'package:http/http.dart' as http;

Map<String, Object?> quoteFixture({
  String symbol = 'AAPL',
  bool twelve = false,
  bool schwab = false,
}) {
  final provider = schwab
      ? 'schwab'
      : twelve
      ? 'twelveData'
      : 'alpaca';
  final feed = schwab
      ? 'schwabEquity'
      : twelve
      ? 'twelveDataUsEquityUnverified'
      : 'iex';
  return {
    'provider': provider,
    'feed': feed,
    'coverage': 'Fixture coverage only',
    'data': {
      'symbol': symbol,
      'provider': provider,
      'feed': feed,
      'retrievedAt': '2026-10-11T20:00:00Z',
      'lastPrice': 123.5,
      'lastTradeAt': '2026-10-11T19:59:50Z',
      'bidPrice': null,
      'askPrice': null,
      'quoteAt': null,
      'freshness': schwab
          ? 'delayed'
          : twelve
          ? 'unavailable'
          : 'fresh',
      if (schwab) ...{
        'realtime': false,
        'quoteType': 'NFL',
        'totalVolume': 150000,
      },
    },
  };
}

Map<String, Object?> barsFixture({
  String symbol = 'AAPL',
  bool twelve = false,
  bool schwab = false,
}) {
  final provider = schwab
      ? 'schwab'
      : twelve
      ? 'twelveData'
      : 'alpaca';
  final feed = schwab
      ? 'schwabEquity'
      : twelve
      ? 'endOfDay'
      : 'iex';
  final now = DateTime.now().toUtc();
  final day = DateTime.utc(
    now.year,
    now.month,
    now.day,
  ).subtract(const Duration(days: 1));
  return {
    'provider': provider,
    'feed': feed,
    'coverage': 'Fixture coverage only',
    'count': 1,
    'data': [
      {
        'symbol': symbol,
        'provider': provider,
        'feed': feed,
        'timestamp': day.toIso8601String(),
        'retrievedAt': now.toIso8601String(),
        'adjustment': schwab ? 'unknown' : 'raw',
        'open': 121.0,
        'high': 125.0,
        'low': 120.0,
        'close': 123.5,
        'volume': 1000,
        'tradeCount': null,
        'volumeWeightedPrice': null,
        if (schwab) 'timestampSemantics': 'utcDateProxy',
        if (twelve) ...{
          'tradingDate': day.toIso8601String().substring(0, 10),
          'exchangeTimezone': 'America/New_York',
          'timestampSemantics': 'exchangeTradingDate',
        },
      },
    ],
  };
}

Map<String, Object?> cardRequestFixture(
  http.Request request, {
  bool twelve = false,
  bool schwab = false,
}) {
  final symbol = request.url.queryParameters['symbol']!;
  if (request.url.path.endsWith('/bars')) {
    return barsFixture(symbol: symbol, twelve: twelve, schwab: schwab);
  }
  if (!request.url.path.endsWith('/quote')) {
    throw StateError('Unexpected automatic request: ${request.url.path}');
  }
  return quoteFixture(symbol: symbol, twelve: twelve, schwab: schwab);
}

http.Response fixtureResponse(Map<String, Object?> body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);
