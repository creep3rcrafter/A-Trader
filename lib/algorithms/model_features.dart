/// Shared, fixed model inputs used during training and pinned inference.
library;

import 'dart:math' as math;
import '../strategy_api.dart';

const liveModelFeatureSchema = 'live_candle_v1';
const liveModelFeatureNames = [
  'closeReturn',
  'bodyReturn',
  'rangeFraction',
  'closeLocation',
  'volumeChange',
];

/// Fixed, scale-free bounded features shared exactly by collection/inference.
List<double> liveCandleFeatures(Candle previous, Candle current) => [
  (current.close / previous.close - 1).clamp(-1.0, 1.0),
  (current.close / current.open - 1).clamp(-1.0, 1.0),
  ((current.high - current.low) / current.close).clamp(0.0, 1.0),
  current.high == current.low
      ? 0
      : (2 * (current.close - current.low) / (current.high - current.low) - 1)
            .clamp(-1.0, 1.0),
  ((current.volume - previous.volume) /
          math.max(1, current.volume + previous.volume))
      .clamp(-1.0, 1.0),
];

bool isValidModelCandle(Candle candle) =>
    candle.symbol.isNotEmpty &&
    [
      candle.open,
      candle.high,
      candle.low,
      candle.close,
      candle.volume,
    ].every((value) => value.isFinite) &&
    candle.open > 0 &&
    candle.close > 0 &&
    candle.low > 0 &&
    candle.high >= math.max(candle.open, candle.close) &&
    candle.low <= math.min(candle.open, candle.close) &&
    candle.volume >= 0;
