import 'dart:collection';

import '../strategy_api.dart';

const nativeAlgorithmProtocolVersion = 6;
const _cacheLimit = 16;

/// Send only newly closed candles, once per engine/candle rather than once per
/// tuning candidate. Small bounded caches keep completed replay engines out.
class AlgorithmMarketEncoder {
  final _engines = <String, Map<String, ({int length, String? lastKey})>>{};

  Map<String, Object?> encode(StrategyContext context) {
    final cursors = _engines.remove(context.executionId) ?? {};
    _engines[context.executionId] = cursors;
    if (_engines.length > _cacheLimit) _engines.remove(_engines.keys.first);
    final series = <String, Object?>{};
    void append(String key, List<Candle> bars) {
      final previous = cursors[key];
      final continuous =
          previous != null &&
          previous.length <= bars.length &&
          (previous.length == 0 ||
              bars[previous.length - 1].key == previous.lastKey);
      final from = continuous ? previous.length : 0;
      series[key] = {
        'from': from,
        'bars': [
          for (var i = from; i < bars.length; i++)
            encodeAlgorithmCandle(bars[i]),
        ],
      };
      cursors[key] = (length: bars.length, lastKey: bars.lastOrNull?.key);
    }

    append('@current', context.candles);
    for (final entry in context.watchlist.entries) {
      append(entry.key, entry.value);
    }
    return {'executionId': context.executionId, 'series': series};
  }
}

class AlgorithmMarketDecoder {
  final _engines = <String, Map<String, List<Candle>>>{};

  ({List<Candle> candles, Map<String, List<Candle>> watchlist}) apply(Map raw) {
    final key = raw['executionId'] as String;
    final history = _engines.remove(key) ?? {};
    _engines[key] = history;
    if (_engines.length > _cacheLimit) _engines.remove(_engines.keys.first);
    for (final entry in (raw['series'] as Map).entries) {
      final update = entry.value as Map;
      final from = update['from'] as int;
      final bars = history.putIfAbsent(entry.key as String, () => []);
      if (from == 0) bars.clear();
      if (bars.length != from) {
        throw StateError('Imported algorithm market history is out of sync.');
      }
      bars.addAll(
        (update['bars'] as List).map((bar) => _decodeCandle(bar as Map)),
      );
    }
    return (
      candles: UnmodifiableListView(history['@current']!),
      watchlist: Map.unmodifiable({
        for (final entry in history.entries)
          if (entry.key != '@current')
            entry.key: UnmodifiableListView(entry.value),
      }),
    );
  }
}

Map<String, Object?> encodeAlgorithmCandle(Candle bar) => {
  'symbol': bar.symbol,
  'time': bar.time.toUtc().toIso8601String(),
  'open': bar.open,
  'high': bar.high,
  'low': bar.low,
  'close': bar.close,
  'volume': bar.volume,
};

Candle _decodeCandle(Map raw) => Candle(
  symbol: raw['symbol'] as String,
  time: DateTime.parse(raw['time'] as String),
  open: (raw['open'] as num).toDouble(),
  high: (raw['high'] as num).toDouble(),
  low: (raw['low'] as num).toDouble(),
  close: (raw['close'] as num).toDouble(),
  volume: (raw['volume'] as num).toDouble(),
);
