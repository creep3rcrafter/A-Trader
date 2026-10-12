import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:a_trade/market_data/daily_indicators.dart';
import 'package:a_trade/market_data/market_data.dart';

const _cutoff = '2026-10-10T12:00:00Z';
const _dates = [
  '2026-10-05',
  '2026-10-06',
  '2026-10-07',
  '2026-10-08',
  '2026-10-09',
];

DailyIndicatorConfig _config({
  String symbol = 'AAPL',
  MarketDataProvider provider = MarketDataProvider.alpaca,
  MarketDataFeed feed = MarketDataFeed.iex,
  PriceAdjustment adjustment = PriceAdjustment.raw,
  DateTime? cutoff,
  String latest = '2026-10-09',
  Duration maxAge = const Duration(days: 2),
  int lookback = 2,
  int trendLag = 1,
  int rsiPeriod = 14,
  List<String>? expectedDates = _dates,
  bool comparable = false,
}) => DailyIndicatorConfig(
  symbol: symbol,
  provider: provider,
  feed: feed,
  adjustment: adjustment,
  analysisCutoff: cutoff ?? DateTime.parse(_cutoff).toUtc(),
  latestCompletedSessionDate: latest,
  maximumRetrievalAge: maxAge,
  lookback: lookback,
  trendLag: trendLag,
  rsiPeriod: rsiPeriod,
  expectedSessionDates: expectedDates,
  corporateActionComparabilityConfirmed: comparable,
);

List<MarketBar> _bars({
  List<String> dates = _dates,
  List<double>? opens,
  List<double>? closes,
  List<int>? volumes,
  List<DateTime>? retrievedAt,
  MarketDataProvider provider = MarketDataProvider.alpaca,
  MarketDataFeed feed = MarketDataFeed.iex,
  PriceAdjustment adjustment = PriceAdjustment.raw,
  String? symbol = 'AAPL',
  List<String>? symbols,
  List<MarketDataFeed>? feeds,
  List<String?>? tradingDates,
  List<String?>? timezones,
}) {
  final actualOpens = opens ?? [9, 11, 12, 11, 14];
  final actualCloses = closes ?? [10, 11, 12, 10, 15];
  final actualVolumes = volumes ?? [10, 20, 30, 50, 40];
  return List.generate(dates.length, (index) {
    final parts = dates[index].split('-').map(int.parse).toList();
    return MarketBar(
      symbol: symbols?[index] ?? symbol!,
      provider: provider,
      feed: feeds?[index] ?? feed,
      timestamp: DateTime.utc(parts[0], parts[1], parts[2], 16),
      retrievedAt:
          retrievedAt?[index] ??
          DateTime.parse(_cutoff).toUtc().subtract(const Duration(minutes: 1)),
      adjustment: adjustment,
      open: actualOpens[index],
      high: [
        actualOpens[index],
        actualCloses[index],
      ].reduce((left, right) => left > right ? left : right),
      low: [
        actualOpens[index],
        actualCloses[index],
      ].reduce((left, right) => left < right ? left : right),
      close: actualCloses[index],
      volume: actualVolumes[index],
      tradingDate: tradingDates?[index],
      exchangeTimezone: timezones?[index],
    );
  });
}

void main() {
  group('DailyIndicatorEngine', () {
    test('computes normalized SMA trend with explicit lag and direction', () {
      for (final fixture in [
        ([1.0, 2.0, 3.0, 4.0, 5.0], 0.8, SmaTrendDirection.rising),
        ([5.0, 4.0, 3.0, 2.0, 1.0], -4 / 7, SmaTrendDirection.falling),
        ([3.0, 3.0, 3.0, 3.0, 3.0], 0.0, SmaTrendDirection.flat),
      ]) {
        final result = DailyIndicatorEngine.calculate(
          config: _config(trendLag: 2),
          bars: _bars(opens: fixture.$1, closes: fixture.$1),
        );
        expect(
          result.smaTrend.value!.normalizedSlope,
          closeTo(fixture.$2, 1e-10),
        );
        expect(result.smaTrend.value!.direction, fixture.$3);
        expect(result.smaTrend.requiredSampleCount, 4);
        expect(result.smaTrend.observedSampleCount, 4);
        expect(result.smaTrend.startSessionDate, _dates[1]);
        expect(result.smaTrend.parameters, {'N': 2, 'K': 2});
      }
    });

    test(
      'EMA uses first N-close seed and independent recurrence checkpoints',
      () {
        // N=3: seed=(10+11+12)/3=11, then 10.5, then 12.75.
        for (final checkpoint in [(3, 11.0), (4, 10.5), (5, 12.75)]) {
          final dates = _dates.take(checkpoint.$1).toList();
          final result = DailyIndicatorEngine.calculate(
            config: _config(
              lookback: 3,
              latest: dates.last,
              expectedDates: dates,
            ),
            bars: _bars(dates: dates),
          );
          final ema = result.exponentialMovingAverage;
          expect(ema.value, closeTo(checkpoint.$2, 1e-10));
          expect(ema.requiredSampleCount, 3);
          expect(ema.observedSampleCount, checkpoint.$1);
          expect(ema.startSessionDate, _dates.first);
          expect(ema.endSessionDate, dates.last);
          expect(ema.parameters['alpha'], 0.5);
          expect(ema.parameters['initializationSampleCount'], 3);
          expect(ema.parameters['warmupSampleCount'], 3);
        }
      },
    );

    test(
      'Wilder RSI uses first deltas and independent seed/recurrence checkpoints',
      () {
        // P=2 deltas +1,+1 => (gain,loss)=(1,0) => 100.
        // Next -2 => (0.5,1) => 100/3; next +5 => (2.75,0.5) => 1100/13.
        for (final checkpoint in [(3, 100.0), (4, 100 / 3), (5, 1100 / 13)]) {
          final dates = _dates.take(checkpoint.$1).toList();
          final result = DailyIndicatorEngine.calculate(
            config: _config(
              rsiPeriod: 2,
              latest: dates.last,
              expectedDates: dates,
            ),
            bars: _bars(dates: dates),
          );
          final rsi = result.relativeStrengthIndex;
          expect(rsi.value, closeTo(checkpoint.$2, 1e-10));
          expect(rsi.requiredSampleCount, 3);
          expect(rsi.observedSampleCount, checkpoint.$1);
          expect(rsi.parameters['initializationDeltaCount'], 2);
          expect(rsi.parameters['initializationSampleCount'], 3);
          expect(rsi.parameters['warmupSampleCount'], 3);
        }
      },
    );

    test('default RSI seeds 14 deltas then applies Wilder smoothing', () {
      final dates = List.generate(
        17,
        (i) => '2026-09-${(i + 1).toString().padLeft(2, '0')}',
      );
      final closes = [...List.generate(15, (i) => 10.0 + i), 22.0, 25.0];
      // Fourteen +1 deltas seed (1,0). Next -2 => (13/14,2/14),
      // next +3 => (211/196,26/196), RSI = 21100/237.
      for (final checkpoint in [
        (14, null),
        (15, 100.0),
        (16, 260 / 3),
        (17, 21100 / 237),
      ]) {
        final prefix = dates.take(checkpoint.$1).toList();
        final result = DailyIndicatorEngine.calculate(
          config: _config(latest: prefix.last, expectedDates: prefix),
          bars: _bars(
            dates: prefix,
            opens: closes,
            closes: closes,
            volumes: List.filled(dates.length, 1),
          ),
        );
        expect(result.rsiPeriod, 14);
        expect(result.relativeStrengthIndex.requiredSampleCount, 15);
        if (checkpoint.$2 == null) {
          expect(
            result.relativeStrengthIndex.unavailableReason,
            DailyIndicatorUnavailableReason.insufficientData,
          );
        } else {
          expect(
            result.relativeStrengthIndex.value,
            closeTo(checkpoint.$2!, 1e-10),
          );
        }
      }
    });

    test(
      'RSI rising falling and flat conventions are available on raw prices',
      () {
        for (final fixture in [
          ([1.0, 2.0, 3.0, 4.0, 5.0], 100.0, 4.5),
          ([5.0, 4.0, 3.0, 2.0, 1.0], 0.0, 1.5),
          ([3.0, 3.0, 3.0, 3.0, 3.0], 50.0, 3.0),
        ]) {
          final result = DailyIndicatorEngine.calculate(
            config: _config(rsiPeriod: 2),
            bars: _bars(opens: fixture.$1, closes: fixture.$1),
          );
          expect(result.relativeStrengthIndex.value, fixture.$2);
          expect(result.exponentialMovingAverage.isAvailable, isTrue);
          expect(
            result.exponentialMovingAverage.value,
            closeTo(fixture.$3, 1e-10),
          );
          expect(result.smaTrend.isAvailable, isTrue);
          expect(
            result.closeReturn.unavailableReason,
            DailyIndicatorUnavailableReason.nonComparableRawPrices,
          );
          expect(
            result.limitations.any(
              (text) => text.contains('without a comparability gate'),
            ),
            isTrue,
          );
        }
      },
    );

    test('N-1 N and N+1 expose initialization and trend boundaries', () {
      for (final count in [2, 3, 4]) {
        final dates = _dates.take(count).toList();
        final result = DailyIndicatorEngine.calculate(
          config: _config(
            lookback: 3,
            rsiPeriod: 3,
            latest: dates.last,
            expectedDates: dates,
          ),
          bars: _bars(dates: dates),
        );
        expect(result.exponentialMovingAverage.isAvailable, count >= 3);
        expect(result.smaTrend.isAvailable, count >= 4);
        expect(result.relativeStrengthIndex.isAvailable, count >= 4);
        expect(result.smaTrend.requiredSampleCount, 4);
        expect(result.relativeStrengthIndex.requiredSampleCount, 4);
        if (count < 3) {
          expect(
            result.exponentialMovingAverage.unavailableReason,
            DailyIndicatorUnavailableReason.insufficientData,
          );
        }
      }
    });

    test('recursive metrics never compress historical missing sessions', () {
      final bars = _bars()..removeAt(0);
      final result = DailyIndicatorEngine.calculate(
        config: _config(rsiPeriod: 2),
        bars: bars,
      );
      expect(result.simpleMovingAverage.isAvailable, isTrue);
      expect(result.smaTrend.isAvailable, isTrue);
      for (final metric in [
        result.exponentialMovingAverage,
        result.relativeStrengthIndex,
      ]) {
        expect(
          metric.unavailableReason,
          DailyIndicatorUnavailableReason.incompleteCoverage,
        );
        expect(metric.missingSessionDates, [_dates.first]);
        expect(metric.startSessionDate, _dates.first);
        expect(metric.observedSampleCount, 4);
      }
      final internalGap = _bars()..removeAt(3);
      final gapResult = DailyIndicatorEngine.calculate(
        config: _config(rsiPeriod: 2),
        bars: internalGap,
      );
      expect(
        gapResult.exponentialMovingAverage.unavailableReason,
        DailyIndicatorUnavailableReason.incompleteCoverage,
      );
      expect(
        gapResult.relativeStrengthIndex.unavailableReason,
        DailyIndicatorUnavailableReason.incompleteCoverage,
      );
      expect(
        gapResult.smaTrend.unavailableReason,
        DailyIndicatorUnavailableReason.incompleteCoverage,
      );
    });

    test(
      'stale seeded samples block recursions but not fresh trailing metrics',
      () {
        final fresh = DateTime.parse(
          _cutoff,
        ).subtract(const Duration(seconds: 1));
        final result = DailyIndicatorEngine.calculate(
          config: _config(maxAge: const Duration(minutes: 5), rsiPeriod: 2),
          bars: _bars(
            retrievedAt: [
              fresh.subtract(const Duration(days: 1)),
              fresh,
              fresh,
              fresh,
              fresh,
            ],
          ),
        );
        expect(result.smaTrend.isAvailable, isTrue);
        expect(result.simpleMovingAverage.isAvailable, isTrue);
        for (final metric in [
          result.exponentialMovingAverage,
          result.relativeStrengthIndex,
        ]) {
          expect(
            metric.unavailableReason,
            DailyIndicatorUnavailableReason.staleData,
          );
          expect(metric.staleSampleCount, 1);
          expect(metric.retrievalTimes, hasLength(5));
        }
      },
    );

    test('new metrics preserve unverified and empty input unavailability', () {
      for (final empty in [false, true]) {
        final result = DailyIndicatorEngine.calculate(
          config: _config(expectedDates: null),
          bars: empty ? [] : _bars(),
        );
        for (final metric in [
          result.smaTrend,
          result.exponentialMovingAverage,
          result.relativeStrengthIndex,
        ]) {
          expect(
            metric.unavailableReason,
            empty
                ? DailyIndicatorUnavailableReason.insufficientData
                : DailyIndicatorUnavailableReason.coverageUnverified,
          );
        }
      }
    });

    test(
      'history start anchors seeds and ignores bars outside expected history',
      () {
        final dates = _dates.skip(1).toList();
        final fullBars = _bars();
        final prefixBefore = DailyIndicatorEngine.calculate(
          config: _config(lookback: 3, rsiPeriod: 2),
          bars: fullBars,
        );
        final config = _config(lookback: 3, rsiPeriod: 2, expectedDates: dates);
        final withExtra = DailyIndicatorEngine.calculate(
          config: config,
          bars: fullBars,
        );
        final withoutExtra = DailyIndicatorEngine.calculate(
          config: config,
          bars: fullBars.skip(1).toList(),
        );
        // New earliest seed (11+12+10)/3=11, then (11+15)/2=13.
        expect(withExtra.exponentialMovingAverage.value, 13);
        // Seed gains/losses=(0.5,1), then (2.75,0.5).
        expect(
          withExtra.relativeStrengthIndex.value,
          closeTo(1100 / 13, 1e-10),
        );
        expect(prefixBefore.exponentialMovingAverage.value, 12.75);
        expect(
          withExtra.exponentialMovingAverage.toJson(),
          withoutExtra.exponentialMovingAverage.toJson(),
        );
        expect(
          withExtra.relativeStrengthIndex.toJson(),
          withoutExtra.relativeStrengthIndex.toJson(),
        );
        expect(
          withExtra.exponentialMovingAverage.startSessionDate,
          dates.first,
        );
      },
    );

    test(
      'recursive history is preserved on extension and prefix repeats exactly',
      () {
        final dates = _dates.take(4).toList();
        final config = _config(
          lookback: 3,
          rsiPeriod: 2,
          latest: dates.last,
          expectedDates: dates,
        );
        final prefix = DailyIndicatorEngine.calculate(
          config: config,
          bars: _bars(dates: dates),
        );
        final extended = DailyIndicatorEngine.calculate(
          config: _config(lookback: 3, rsiPeriod: 2),
          bars: _bars(),
        );
        final repeatedPrefix = DailyIndicatorEngine.calculate(
          config: config,
          bars: _bars().take(4).toList(),
        );
        expect(prefix.toJson(), repeatedPrefix.toJson());
        expect(prefix.exponentialMovingAverage.value, 10.5);
        expect(extended.exponentialMovingAverage.value, 12.75);
        expect(extended.relativeStrengthIndex.value, closeTo(1100 / 13, 1e-10));
        expect(extended.exponentialMovingAverage.startSessionDate, dates.first);
      },
    );

    test('new periods validate defaults and both supported boundaries', () {
      expect(_config().trendLag, 1);
      expect(_config().rsiPeriod, 14);
      for (final period in [0, -1, 5001]) {
        expect(
          () => _config(trendLag: period),
          throwsA(isA<DailyIndicatorValidationException>()),
        );
        expect(
          () => _config(rsiPeriod: period),
          throwsA(isA<DailyIndicatorValidationException>()),
        );
      }
      for (final period in [1, 5000]) {
        expect(_config(trendLag: period).trendLag, period);
        expect(_config(rsiPeriod: period).rsiPeriod, period);
      }
    });

    test(
      'completed date cannot be a later UTC date even without expected dates',
      () {
        for (final expected in [
          null,
          ['2026-10-11'],
        ]) {
          expect(
            () => _config(latest: '2026-10-11', expectedDates: expected),
            throwsA(isA<DailyIndicatorValidationException>()),
          );
        }
        expect(
          _config(
            latest: '2026-10-10',
            expectedDates: ['2026-10-10'],
          ).latestCompletedSessionDate,
          '2026-10-10',
        );
      },
    );

    test(
      'finite extremes do not overflow EMA Wilder means or serialized trend',
      () {
        final large = _bars(
          opens: List.filled(5, 1.7e308),
          closes: List.filled(5, 1.7e308),
        );
        final stable = DailyIndicatorEngine.calculate(
          config: _config(lookback: 3, rsiPeriod: 2),
          bars: large,
        );
        expect(stable.exponentialMovingAverage.value, 1.7e308);
        expect(stable.smaTrend.value!.normalizedSlope, 0);
        expect(stable.relativeStrengthIndex.value, 50);
        final alternating = _bars(
          opens: [1e-308, 1.7e308, 1e-308, 1.7e308, 1e-308],
          closes: [1e-308, 1.7e308, 1e-308, 1.7e308, 1e-308],
        );
        final result = DailyIndicatorEngine.calculate(
          config: _config(lookback: 2, rsiPeriod: 2),
          bars: alternating,
        );
        expect(result.exponentialMovingAverage.value!.isFinite, isTrue);
        expect(result.relativeStrengthIndex.value, closeTo(37.5, 1e-10));
        final one = DailyIndicatorEngine.calculate(
          config: _config(lookback: 1, rsiPeriod: 1),
          bars: alternating,
        );
        expect(one.exponentialMovingAverage.value, 1e-308);
        expect(one.relativeStrengthIndex.value, 0);
        final overflowingTrend = DailyIndicatorEngine.calculate(
          config: _config(lookback: 1),
          bars: _bars(
            opens: [1, 1, 1, 1e-308, 1.7e308],
            closes: [1, 1, 1, 1e-308, 1.7e308],
          ),
        );
        expect(overflowingTrend.smaTrend.value, isNull);
        expect(
          overflowingTrend.smaTrend.unavailableReason,
          DailyIndicatorUnavailableReason.numericalOverflow,
        );
        expect(() => jsonEncode(overflowingTrend.toJson()), returnsNormally);
        expect(() => jsonEncode(result.toJson()), returnsNormally);
      },
    );

    test('v2 new metric JSON names and immutable metadata are stable', () {
      final result = DailyIndicatorEngine.calculate(
        config: _config(rsiPeriod: 2),
        bars: _bars(),
      );
      final json = jsonDecode(jsonEncode(result.toJson())) as Map;
      expect(json['formulaVersion'], 'daily-indicators-v2');
      expect(json['trendLag'], 1);
      expect(json['rsiPeriod'], 2);
      final trend = json['smaTrend'] as Map;
      expect(trend['value'], {
        'slope': result.smaTrend.value!.normalizedSlope,
        'direction': 'rising',
      });
      for (final name in [
        'smaTrend',
        'exponentialMovingAverage',
        'relativeStrengthIndex',
      ]) {
        final metric = json[name] as Map;
        expect(metric['availability'], 'available');
        expect(metric['formulaVersion'], 'daily-indicators-v2');
        expect(metric['unavailableReason'], isNull);
        expect(metric['parameters'], isA<Map>());
        expect(metric['retrievalTimes'], isA<List>());
      }
      expect((json['exponentialMovingAverage'] as Map)['units'], 'price');
      expect((json['relativeStrengthIndex'] as Map)['units'], 'index (0..100)');
      expect(() => result.smaTrend.parameters.clear(), throwsUnsupportedError);
      expect(
        () => result.exponentialMovingAverage.retrievalTimes.clear(),
        throwsUnsupportedError,
      );
      expect(
        () => result.relativeStrengthIndex.missingSessionDates.clear(),
        throwsUnsupportedError,
      );
    });

    test(
      'legacy result construction keeps optional new metrics unavailable',
      () {
        final original = DailyIndicatorEngine.calculate(
          config: _config(),
          bars: _bars(),
        );
        final legacy = DailyIndicatorResult(
          symbol: original.symbol,
          provider: original.provider,
          feed: original.feed,
          adjustment: original.adjustment,
          analysisCutoff: original.analysisCutoff,
          latestCompletedSessionDate: original.latestCompletedSessionDate,
          lookback: original.lookback,
          maximumRetrievalAge: original.maximumRetrievalAge,
          sessionDateSemantics: original.sessionDateSemantics,
          exchangeTimezone: original.exchangeTimezone,
          volumeScope: original.volumeScope,
          corporateActionComparabilityConfirmed:
              original.corporateActionComparabilityConfirmed,
          coverage: original.coverage,
          sessionColors: original.sessionColors,
          greenToRedRatio: original.greenToRedRatio,
          closeReturn: original.closeReturn,
          simpleMovingAverage: original.simpleMovingAverage,
          relativeVolume: original.relativeVolume,
          barProvenance: original.barProvenance,
          limitations: original.limitations,
        );
        expect(
          legacy.simpleMovingAverage.toJson(),
          original.simpleMovingAverage.toJson(),
        );
        expect(legacy.trendLag, 1);
        expect(legacy.rsiPeriod, 14);
        for (final metric in [
          legacy.smaTrend,
          legacy.exponentialMovingAverage,
          legacy.relativeStrengthIndex,
        ]) {
          expect(metric.isAvailable, isFalse);
          expect(metric.observedSampleCount, 0);
          expect(
            metric.unavailableReason,
            DailyIndicatorUnavailableReason.insufficientData,
          );
        }
        expect(() => jsonEncode(legacy.toJson()), returnsNormally);
      },
    );

    test(
      'matches hand-computed colors, return, SMA, and prior-volume mean',
      () {
        final result = DailyIndicatorEngine.calculate(
          config: _config(comparable: true),
          bars: _bars(),
        );

        expect(result.sessionColors.value!.greenCount, 1);
        expect(result.sessionColors.value!.redCount, 1);
        expect(result.sessionColors.value!.flatCount, 0);
        expect(result.sessionColors.value!.greenFraction, 0.5);
        expect(result.sessionColors.value!.redFraction, 0.5);
        expect(result.greenToRedRatio.value, 1);
        expect(result.closeReturn.value, 0.25);
        expect(result.simpleMovingAverage.value, closeTo(12.5, 1e-10));
        expect(result.relativeVolume.value, 1);
        expect(result.closeReturn.units, 'fraction');
        expect(result.sessionColors.requiredSampleCount, 2);
        expect(result.closeReturn.requiredSampleCount, 3);
        expect(result.relativeVolume.requiredSampleCount, 3);
        expect(
          result.relativeVolume.parameters['latestExcludedFromBaseline'],
          true,
        );
      },
    );

    test(
      'reports green:red ratio unavailable when the window has no red days',
      () {
        final opens = [1.0, 1.0, 1.0, 1.0, 1.0];
        final result = DailyIndicatorEngine.calculate(
          config: _config(comparable: true),
          bars: _bars(opens: opens, closes: [1, 2, 2, 3, 4]),
        );

        expect(result.sessionColors.value!.redCount, 0);
        expect(result.greenToRedRatio.isAvailable, isFalse);
        expect(
          result.greenToRedRatio.unavailableReason,
          DailyIndicatorUnavailableReason.zeroDenominator,
        );
      },
    );

    test(
      'reports flat colors and zero latest volume without inventing a ratio',
      () {
        final result = DailyIndicatorEngine.calculate(
          config: _config(comparable: true),
          bars: _bars(
            opens: [1, 2, 3, 10, 15],
            closes: [1, 2, 3, 10, 15],
            volumes: [5, 10, 20, 30, 0],
          ),
        );

        expect(result.sessionColors.value!.flatCount, 2);
        expect(result.sessionColors.value!.flatFraction, 1);
        expect(result.relativeVolume.value, 0);
      },
    );

    test('requires expected sessions and preserves unverified coverage', () {
      final result = DailyIndicatorEngine.calculate(
        config: _config(expectedDates: null, comparable: true),
        bars: _bars(),
      );

      expect(result.coverage.state, DailyIndicatorCoverageState.unverified);
      expect(result.sessionColors.isAvailable, isFalse);
      expect(
        result.sessionColors.unavailableReason,
        DailyIndicatorUnavailableReason.coverageUnverified,
      );
      expect(
        result.closeReturn.unavailableReason,
        DailyIndicatorUnavailableReason.coverageUnverified,
      );
    });

    test(
      'empty input yields insufficient data values, not validation errors',
      () {
        final result = DailyIndicatorEngine.calculate(
          config: _config(comparable: true),
          bars: const [],
        );

        expect(result.coverage.state, DailyIndicatorCoverageState.empty);
        expect(result.sessionColors.observedSampleCount, 0);
        expect(result.sessionColors.requiredSampleCount, 2);
        expect(
          result.sessionColors.unavailableReason,
          DailyIndicatorUnavailableReason.insufficientData,
        );
      },
    );

    test(
      'validates exact expected trailing coverage and ignores older gaps',
      () {
        const expected = [
          '2026-10-01',
          '2026-10-02',
          '2026-10-05',
          '2026-10-06',
          '2026-10-07',
        ];
        final result = DailyIndicatorEngine.calculate(
          config: _config(
            latest: '2026-10-07',
            lookback: 2,
            expectedDates: expected,
            comparable: true,
          ),
          bars: _bars(
            dates: ['2026-10-01', '2026-10-05', '2026-10-06', '2026-10-07'],
            opens: [9, 10, 11, 12],
            closes: [10, 11, 12, 13],
            volumes: [1, 10, 20, 30],
          ),
        );

        expect(result.coverage.state, DailyIndicatorCoverageState.incomplete);
        expect(result.coverage.missingExpectedSessionDates, ['2026-10-02']);
        expect(result.sessionColors.isAvailable, isTrue);
        expect(result.closeReturn.isAvailable, isTrue);
        expect(result.relativeVolume.isAvailable, isTrue);
        expect(result.closeReturn.requiredSampleCount, 3);
        expect(result.closeReturn.startSessionDate, '2026-10-05');
      },
    );

    test('missing latest required date makes trailing metrics incomplete', () {
      final result = DailyIndicatorEngine.calculate(
        config: _config(),
        bars: _bars(dates: _dates.take(4).toList()),
      );

      expect(result.coverage.latestCompletedSessionPresent, isFalse);
      expect(
        result.sessionColors.unavailableReason,
        DailyIndicatorUnavailableReason.incompleteCoverage,
      );
      expect(result.sessionColors.missingSessionDates, ['2026-10-09']);
      expect(
        result.closeReturn.unavailableReason,
        DailyIndicatorUnavailableReason.incompleteCoverage,
      );
    });

    test('reports N versus N+1 sample requirements precisely', () {
      final config = _config(
        lookback: 2,
        latest: '2026-10-07',
        expectedDates: _dates.take(3).toList(),
        comparable: true,
      );
      final result = DailyIndicatorEngine.calculate(
        config: config,
        bars: _bars(dates: _dates.skip(1).take(2).toList()),
      );

      expect(result.sessionColors.isAvailable, isTrue);
      expect(result.simpleMovingAverage.isAvailable, isTrue);
      expect(result.closeReturn.isAvailable, isFalse);
      expect(result.relativeVolume.isAvailable, isFalse);
      expect(result.closeReturn.missingSessionDates, ['2026-10-05']);
      expect(result.relativeVolume.requiredSampleCount, 3);
    });

    test(
      'makes a metric unavailable when any retrieval in its window is stale',
      () {
        final result = DailyIndicatorEngine.calculate(
          config: _config(maxAge: const Duration(minutes: 5), comparable: true),
          bars: _bars(
            retrievedAt: [
              DateTime.parse(
                _cutoff,
              ).toUtc().subtract(const Duration(seconds: 1)),
              DateTime.parse(
                _cutoff,
              ).toUtc().subtract(const Duration(seconds: 1)),
              DateTime.parse(
                _cutoff,
              ).toUtc().subtract(const Duration(seconds: 1)),
              DateTime.parse(_cutoff).toUtc().subtract(const Duration(days: 1)),
              DateTime.parse(
                _cutoff,
              ).toUtc().subtract(const Duration(seconds: 1)),
            ],
          ),
        );

        expect(
          result.sessionColors.unavailableReason,
          DailyIndicatorUnavailableReason.staleData,
        );
        expect(result.sessionColors.staleSampleCount, 1);
        expect(
          result.closeReturn.unavailableReason,
          DailyIndicatorUnavailableReason.staleData,
        );
        expect(result.closeReturn.staleSampleCount, 1);
      },
    );

    test('does not let a stale bar outside a metric lookback suppress it', () {
      final result = DailyIndicatorEngine.calculate(
        config: _config(maxAge: const Duration(minutes: 5), comparable: true),
        bars: _bars(
          retrievedAt: [
            DateTime.parse(_cutoff).toUtc().subtract(const Duration(days: 1)),
            DateTime.parse(_cutoff).toUtc().subtract(const Duration(days: 1)),
            DateTime.parse(
              _cutoff,
            ).toUtc().subtract(const Duration(seconds: 1)),
            DateTime.parse(
              _cutoff,
            ).toUtc().subtract(const Duration(seconds: 1)),
            DateTime.parse(
              _cutoff,
            ).toUtc().subtract(const Duration(seconds: 1)),
          ],
        ),
      );

      expect(result.simpleMovingAverage.isAvailable, isTrue);
      expect(result.closeReturn.isAvailable, isTrue);
      expect(result.coverage.state, DailyIndicatorCoverageState.complete);
    });

    test('requires explicit comparability for raw-price returns only', () {
      final result = DailyIndicatorEngine.calculate(
        config: _config(),
        bars: _bars(),
      );

      expect(result.closeReturn.isAvailable, isFalse);
      expect(
        result.closeReturn.unavailableReason,
        DailyIndicatorUnavailableReason.nonComparableRawPrices,
      );
      expect(result.simpleMovingAverage.isAvailable, isTrue);
      expect(
        result.limitations,
        contains(
          'Raw prices are not established as corporate-action comparable.',
        ),
      );
      final confirmed = DailyIndicatorEngine.calculate(
        config: _config(comparable: true),
        bars: _bars(),
      );
      expect(confirmed.closeReturn.value, 0.25);
    });

    test('keeps adjusted arithmetic returns labelled as non-total-return', () {
      final result = DailyIndicatorEngine.calculate(
        config: _config(adjustment: PriceAdjustment.all),
        bars: _bars(adjustment: PriceAdjustment.all),
      );

      expect(result.closeReturn.value, 0.25);
      expect(
        result.limitations,
        contains(
          'Adjusted prices are used as supplied; returns are arithmetic series returns, not verified total returns.',
        ),
      );
    });

    test('distinguishes partial IEX from full-exchange Twelve Data EOD volume', () {
      final iex = DailyIndicatorEngine.calculate(
        config: _config(comparable: true),
        bars: _bars(),
      );
      expect(iex.volumeScope, 'partial');
      expect(iex.relativeVolume.value, 1);
      expect(
        iex.limitations,
        contains(
          'Volume is partial-feed volume; relative volume compares this same feed only, not consolidated market volume or liquidity.',
        ),
      );

      final exactBars = _bars(
        provider: MarketDataProvider.twelveData,
        feed: MarketDataFeed.endOfDay,
        adjustment: PriceAdjustment.all,
        tradingDates: List<String?>.unmodifiable(_dates),
        timezones: List<String?>.filled(_dates.length, 'America/New_York'),
      );
      final twelveData = DailyIndicatorEngine.calculate(
        config: _config(
          provider: MarketDataProvider.twelveData,
          feed: MarketDataFeed.endOfDay,
          adjustment: PriceAdjustment.all,
        ),
        bars: exactBars,
      );
      expect(twelveData.volumeScope, 'completeButAccountCoverageUnverified');
      expect(twelveData.relativeVolume.value, 1);
      expect(
        twelveData.limitations,
        contains(
          'Twelve Data end-of-day volume is documented as full-exchange volume and available after midnight ET on the next trading day; availability and historical depth still vary by instrument and account.',
        ),
      );
      expect(
        twelveData.sessionDateSemantics,
        DailyIndicatorSessionDateSemantics.exchangeTradingDate,
      );
      expect(twelveData.exchangeTimezone, 'America/New_York');
    });

    test('marks unknown feed volume scope unavailable', () {
      final result = DailyIndicatorEngine.calculate(
        config: _config(feed: MarketDataFeed.unknown),
        bars: _bars(feed: MarketDataFeed.unknown),
      );

      expect(result.relativeVolume.isAvailable, isFalse);
      expect(
        result.relativeVolume.unavailableReason,
        DailyIndicatorUnavailableReason.unsupportedVolumeScope,
      );
      expect(result.sessionColors.isAvailable, isTrue);
      expect(result.volumeScope, 'unsupported');
    });

    test('reports zero baseline volume as a typed unavailable ratio', () {
      final result = DailyIndicatorEngine.calculate(
        config: _config(comparable: true),
        bars: _bars(volumes: [0, 0, 0, 0, 10]),
      );

      expect(result.relativeVolume.isAvailable, isFalse);
      expect(
        result.relativeVolume.unavailableReason,
        DailyIndicatorUnavailableReason.zeroDenominator,
      );
    });

    test('derives and labels Alpaca timestamp-only UTC session dates', () {
      final bars = DailyIndicatorEngine.calculate(
        config: _config(comparable: true),
        bars: _bars(),
      );

      expect(
        bars.sessionDateSemantics,
        DailyIndicatorSessionDateSemantics.utcDateProxy,
      );
      expect(bars.barProvenance.first.sessionDate, _dates.first);
      expect(bars.toJson()['sessionDateSemantics'], 'utcDateProxy');
      expect(
        bars.limitations,
        contains(
          'Session dates are UTC-date proxies derived from source timestamps, not exchange-calendar dates.',
        ),
      );
    });

    test('throws typed validation errors for invalid lookback boundaries', () {
      for (final n in [0, -1, 5001]) {
        expect(
          () => _config(lookback: n),
          throwsA(isA<DailyIndicatorValidationException>()),
        );
      }
      expect(_config(lookback: 1).lookback, 1);
      expect(_config(lookback: 5000).lookback, 5000);
    });

    test('rejects unnormalized symbol and non-UTC cutoff', () {
      expect(
        () => _config(symbol: ' aapl '),
        throwsA(isA<DailyIndicatorValidationException>()),
      );
      expect(
        () => _config(cutoff: DateTime(2026, 10, 10, 12)),
        throwsA(isA<DailyIndicatorValidationException>()),
      );
    });

    test(
      'rejects invalid, unordered, duplicate, or mis-ended expected dates',
      () {
        for (final dates in [
          ['2026-02-30'],
          ['2026-10-07', '2026-10-06'],
          ['2026-10-06', '2026-10-06'],
        ]) {
          expect(
            () => _config(latest: dates.last, expectedDates: dates),
            throwsA(isA<DailyIndicatorValidationException>()),
          );
        }
        expect(
          () => _config(latest: '2026-10-09', expectedDates: ['2026-10-08']),
          throwsA(isA<DailyIndicatorValidationException>()),
        );
      },
    );

    test('rejects duplicate, unordered, and future or unfinished bars', () {
      for (final dates in [
        [_dates[0], _dates[0]],
        [_dates[1], _dates[0]],
      ]) {
        expect(
          () => DailyIndicatorEngine.calculate(
            config: _config(expectedDates: dates, latest: dates.last),
            bars: _bars(dates: dates),
          ),
          throwsA(isA<DailyIndicatorValidationException>()),
        );
      }
      expect(
        () => DailyIndicatorEngine.calculate(
          config: _config(),
          bars: [
            ..._bars(),
            MarketBar(
              symbol: 'AAPL',
              provider: MarketDataProvider.alpaca,
              feed: MarketDataFeed.iex,
              timestamp: DateTime.parse('2026-10-10T16:00:00Z'),
              retrievedAt: DateTime.parse('2026-10-10T11:59:00Z'),
              adjustment: PriceAdjustment.raw,
              open: 1,
              high: 2,
              low: 1,
              close: 2,
              volume: 1,
            ),
          ],
        ),
        throwsA(isA<DailyIndicatorValidationException>()),
      );
    });

    test('rejects future source and retrieval timestamps', () {
      final futureTimestamp = [
        MarketBar(
          symbol: 'AAPL',
          provider: MarketDataProvider.alpaca,
          feed: MarketDataFeed.iex,
          timestamp: DateTime.parse('2026-10-10T12:00:01Z'),
          retrievedAt: DateTime.parse('2026-10-10T11:59:00Z'),
          adjustment: PriceAdjustment.raw,
          open: 1,
          high: 2,
          low: 1,
          close: 2,
          volume: 1,
        ),
      ];
      expect(
        () => DailyIndicatorEngine.calculate(
          config: _config(latest: '2026-10-10', expectedDates: null),
          bars: futureTimestamp,
        ),
        throwsA(isA<DailyIndicatorValidationException>()),
      );

      final futureRetrieval = _bars()
        ..[4] = MarketBar(
          symbol: 'AAPL',
          provider: MarketDataProvider.alpaca,
          feed: MarketDataFeed.iex,
          timestamp: DateTime.parse('2026-10-09T16:00:00Z'),
          retrievedAt: DateTime.parse('2026-10-10T12:00:01Z'),
          adjustment: PriceAdjustment.raw,
          open: 14,
          high: 15,
          low: 14,
          close: 15,
          volume: 40,
        );
      expect(
        () => DailyIndicatorEngine.calculate(
          config: _config(),
          bars: futureRetrieval,
        ),
        throwsA(isA<DailyIndicatorValidationException>()),
      );
    });

    test('rejects retrieval timestamp before source timestamp', () {
      final bars = _bars()
        ..[4] = MarketBar(
          symbol: 'AAPL',
          provider: MarketDataProvider.alpaca,
          feed: MarketDataFeed.iex,
          timestamp: DateTime.parse('2026-10-09T16:00:00Z'),
          retrievedAt: DateTime.parse('2026-10-09T15:59:59Z'),
          adjustment: PriceAdjustment.raw,
          open: 14,
          high: 15,
          low: 14,
          close: 15,
          volume: 40,
        );

      expect(
        () => DailyIndicatorEngine.calculate(config: _config(), bars: bars),
        throwsA(
          isA<DailyIndicatorValidationException>().having(
            (error) => error.message,
            'message',
            contains('must not precede its source timestamp'),
          ),
        ),
      );
    });

    test(
      'rejects mixed identities, adjustments, date semantics, and timezones',
      () {
        final mismatch = _bars()
          ..[4] = _bars(provider: MarketDataProvider.twelveData)[4];
        expect(
          () =>
              DailyIndicatorEngine.calculate(config: _config(), bars: mismatch),
          throwsA(isA<DailyIndicatorValidationException>()),
        );

        final changedAdjustment = _bars()
          ..[4] = _bars(adjustment: PriceAdjustment.all)[4];
        expect(
          () => DailyIndicatorEngine.calculate(
            config: _config(),
            bars: changedAdjustment,
          ),
          throwsA(isA<DailyIndicatorValidationException>()),
        );

        final mixedDates = _bars()
          ..[4] = _bars(
            tradingDates: List<String?>.filled(_dates.length, _dates.last),
            timezones: List<String?>.filled(_dates.length, 'America/New_York'),
          )[4];
        expect(
          () => DailyIndicatorEngine.calculate(
            config: _config(),
            bars: mixedDates,
          ),
          throwsA(isA<DailyIndicatorValidationException>()),
        );

        final differentZones =
            _bars(
                tradingDates: List<String?>.unmodifiable(_dates),
                timezones: List<String?>.filled(
                  _dates.length,
                  'America/New_York',
                ),
              )
              ..[4] = _bars(
                tradingDates: List<String?>.unmodifiable(_dates),
                timezones: [
                  'America/New_York',
                  'America/New_York',
                  'America/New_York',
                  'America/New_York',
                  'America/Chicago',
                ],
              )[4];
        expect(
          () => DailyIndicatorEngine.calculate(
            config: _config(),
            bars: differentZones,
          ),
          throwsA(isA<DailyIndicatorValidationException>()),
        );

        for (final mixedBars in [
          _bars(symbols: ['AAPL', 'AAPL', 'AAPL', 'AAPL', 'MSFT']),
          _bars(
            feeds: [
              MarketDataFeed.iex,
              MarketDataFeed.iex,
              MarketDataFeed.iex,
              MarketDataFeed.iex,
              MarketDataFeed.sip,
            ],
          ),
        ]) {
          expect(
            () => DailyIndicatorEngine.calculate(
              config: _config(),
              bars: mixedBars,
            ),
            throwsA(isA<DailyIndicatorValidationException>()),
          );
        }
      },
    );

    test('rejects timezone without trading date and unknown adjustments', () {
      final timezoneOnly = _bars()
        ..[4] = MarketBar(
          symbol: 'AAPL',
          provider: MarketDataProvider.alpaca,
          feed: MarketDataFeed.iex,
          timestamp: DateTime.parse('2026-10-09T16:00:00Z'),
          retrievedAt: DateTime.parse(_cutoff).toUtc(),
          adjustment: PriceAdjustment.raw,
          open: 14,
          high: 15,
          low: 14,
          close: 15,
          volume: 40,
          exchangeTimezone: 'America/New_York',
        );
      expect(
        () => DailyIndicatorEngine.calculate(
          config: _config(),
          bars: timezoneOnly,
        ),
        throwsA(isA<DailyIndicatorValidationException>()),
      );
      expect(
        () => _config(adjustment: PriceAdjustment.unknown),
        throwsA(isA<DailyIndicatorValidationException>()),
      );
    });

    test('rejects impossible explicit trading dates and empty timezones', () {
      final invalidDate = _bars(
        tradingDates: [..._dates.take(4), '2026-02-30'],
        timezones: List<String?>.filled(_dates.length, 'America/New_York'),
      );
      expect(
        () => DailyIndicatorEngine.calculate(
          config: _config(),
          bars: invalidDate,
        ),
        throwsA(isA<DailyIndicatorValidationException>()),
      );

      final emptyTimezone = _bars(
        tradingDates: List<String?>.unmodifiable(_dates),
        timezones: List<String?>.filled(_dates.length, ''),
      );
      expect(
        () => DailyIndicatorEngine.calculate(
          config: _config(),
          bars: emptyTimezone,
        ),
        throwsA(isA<DailyIndicatorValidationException>()),
      );
    });

    test('returns numericalOverflow instead of an infinite close return', () {
      final dates = ['2026-10-08', '2026-10-09'];
      final bars = _bars(
        dates: dates,
        opens: [1e-308, 1e308],
        closes: [1e-308, 1e308],
        volumes: [1, 1],
      );
      final result = DailyIndicatorEngine.calculate(
        config: _config(
          latest: dates.last,
          lookback: 1,
          expectedDates: dates,
          comparable: true,
        ),
        bars: bars,
      );

      expect(result.closeReturn.value, isNull);
      expect(
        result.closeReturn.unavailableReason,
        DailyIndicatorUnavailableReason.numericalOverflow,
      );
      expect(result.simpleMovingAverage.value, 1e308);
    });

    test(
      'defensively copies config and result collections and serializes provenance',
      () {
        final sourceDates = List<String>.of(_dates);
        final config = _config(expectedDates: sourceDates, comparable: true);
        sourceDates.clear();
        final sourceBars = _bars();
        final result = DailyIndicatorEngine.calculate(
          config: config,
          bars: sourceBars,
        );
        sourceBars.clear();

        expect(config.expectedSessionDates, _dates);
        expect(result.barProvenance, hasLength(5));
        expect(
          () => config.expectedSessionDates!.add('2026-10-12'),
          throwsUnsupportedError,
        );
        expect(() => result.barProvenance.clear(), throwsUnsupportedError);
        final json = result.toJson();
        expect(json['provider'], 'alpaca');
        expect(json['feed'], 'iex');
        expect(json['formulaVersion'], dailyIndicatorFormulaVersion);
        expect((json['closeReturn'] as Map)['units'], 'fraction');
        expect((json['relativeVolume'] as Map)['availability'], 'available');
        expect((json['barProvenance'] as List).length, 5);
        expect(
          json['maximumRetrievalAgeMicroseconds'],
          config.maximumRetrievalAge.inMicroseconds,
        );
        expect((json['coverage'] as Map)['expectedSessionDates'], _dates);
      },
    );

    test('is deterministic and invariant when future bars are appended', () {
      final earlierDates = _dates.take(3).toList();
      final earlier = DailyIndicatorEngine.calculate(
        config: _config(
          latest: earlierDates.last,
          lookback: 1,
          expectedDates: earlierDates,
          comparable: true,
        ),
        bars: _bars(dates: earlierDates).sublist(0, 3),
      );
      final full = DailyIndicatorEngine.calculate(
        config: _config(lookback: 1, comparable: true),
        bars: _bars(),
      );
      final repeated = DailyIndicatorEngine.calculate(
        config: _config(lookback: 1, comparable: true),
        bars: _bars(),
      );

      expect(earlier.closeReturn.value, closeTo(1 / 11, 1e-10));
      expect(earlier.relativeVolume.value, 1.5);
      expect(full.toJson(), repeated.toJson());

      final samePrefix = DailyIndicatorEngine.calculate(
        config: _config(
          latest: earlierDates.last,
          lookback: 1,
          expectedDates: earlierDates,
          comparable: true,
        ),
        bars: _bars(dates: earlierDates),
      );
      expect(earlier.toJson(), samePrefix.toJson());
    });
  });
}
