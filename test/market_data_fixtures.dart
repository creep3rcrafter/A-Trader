import 'dart:convert';

import 'package:http/http.dart' as http;

Map<String, Object?> quoteFixture({
  String symbol = 'AAPL',
  bool twelve = false,
}) {
  final provider = twelve ? 'twelveData' : 'alpaca';
  final feed = twelve ? 'twelveDataUsEquityUnverified' : 'iex';
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
      'freshness': twelve ? 'unavailable' : 'fresh',
    },
  };
}

Map<String, Object?> barsFixture({
  String symbol = 'AAPL',
  bool twelve = false,
}) {
  final provider = twelve ? 'twelveData' : 'alpaca';
  final feed = twelve ? 'endOfDay' : 'iex';
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
        'adjustment': 'raw',
        'open': 121.0,
        'high': 125.0,
        'low': 120.0,
        'close': 123.5,
        'volume': 1000,
        'tradeCount': null,
        'volumeWeightedPrice': null,
        if (twelve) ...{
          'tradingDate': day.toIso8601String().substring(0, 10),
          'exchangeTimezone': 'America/New_York',
          'timestampSemantics': 'exchangeTradingDate',
        },
      },
    ],
  };
}

http.Response fixtureResponse(Map<String, Object?> body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);
