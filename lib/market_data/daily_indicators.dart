import 'dart:math' as math;

import 'market_data.dart';

const String dailyIndicatorFormulaVersion = 'daily-indicators-v2';
const int minimumDailyIndicatorLookback = 1;
const int maximumDailyIndicatorLookback = 5000;

enum DailyIndicatorUnavailableReason {
  insufficientData,
  coverageUnverified,
  incompleteCoverage,
  staleData,
  zeroDenominator,
  unsupportedVolumeScope,
  nonComparableRawPrices,
  numericalOverflow,
}

enum DailyIndicatorCoverageState { empty, unverified, complete, incomplete }

enum DailyIndicatorSessionDateSemantics { exchangeTradingDate, utcDateProxy }

enum SmaTrendDirection { rising, falling, flat }

class SmaTrend {
  const SmaTrend({required this.normalizedSlope});

  final double normalizedSlope;

  SmaTrendDirection get direction => normalizedSlope > 0
      ? SmaTrendDirection.rising
      : normalizedSlope < 0
      ? SmaTrendDirection.falling
      : SmaTrendDirection.flat;

  Map<String, Object?> toJson() => {
    'slope': normalizedSlope,
    'direction': direction.name,
  };
}

class DailyIndicatorValidationException implements Exception {
  const DailyIndicatorValidationException(this.message);

  final String message;

  @override
  String toString() => 'DailyIndicatorValidationException: $message';
}

class DailyIndicatorConfig {
  DailyIndicatorConfig({
    required this.symbol,
    required this.provider,
    required this.feed,
    required this.adjustment,
    required this.analysisCutoff,
    required this.latestCompletedSessionDate,
    required this.maximumRetrievalAge,
    required this.lookback,
    this.trendLag = 1,
    this.rsiPeriod = 14,
    List<String>? expectedSessionDates,
    this.corporateActionComparabilityConfirmed = false,
  }) : expectedSessionDates = expectedSessionDates == null
           ? null
           : List<String>.unmodifiable(expectedSessionDates) {
    DailyIndicatorInputValidator.validateConfig(this);
  }

  final String symbol;
  final MarketDataProvider provider;
  final MarketDataFeed feed;
  final PriceAdjustment adjustment;
  final DateTime analysisCutoff;
  final String latestCompletedSessionDate;

  /// Required; age is measured from each bar's retrieval time to cutoff.
  /// There is intentionally no implicit freshness threshold.
  final Duration maximumRetrievalAge;
  final int lookback;

  /// SMA trend compares N-close means K expected sessions apart.
  final int trendLag;
  final int rsiPeriod;

  /// EMA and RSI seed at the earliest supplied expected session and consume
  /// this entire history, not just the trailing initialization window. Earlier
  /// bars outside this set are provenance only. Changing its start changes the
  /// seed; gaps or stale samples anywhere in this set block recursive metrics.
  final List<String>? expectedSessionDates;
  final bool corporateActionComparabilityConfirmed;
}

class DailyIndicatorInputValidator {
  const DailyIndicatorInputValidator._();

  static void validateConfig(DailyIndicatorConfig config) {
    if (!_isNormalizedSymbol(config.symbol)) {
      throw const DailyIndicatorValidationException(
        'Symbol must be a normalized uppercase ticker.',
      );
    }
    if (!config.analysisCutoff.isUtc) {
      throw const DailyIndicatorValidationException(
        'Analysis cutoff must be a UTC instant.',
      );
    }
    _validateDate(config.latestCompletedSessionDate, 'Latest completed date');
    if (config.latestCompletedSessionDate.compareTo(
          _dateFromUtc(config.analysisCutoff),
        ) >
        0) {
      throw const DailyIndicatorValidationException(
        'Latest completed session date must not be after the UTC analysis cutoff date.',
      );
    }
    if (config.maximumRetrievalAge.inMicroseconds <= 0) {
      throw const DailyIndicatorValidationException(
        'Maximum retrieval age must be positive.',
      );
    }
    if (config.lookback < minimumDailyIndicatorLookback ||
        config.lookback > maximumDailyIndicatorLookback) {
      throw const DailyIndicatorValidationException(
        'Lookback must be between 1 and 5000 sessions.',
      );
    }
    if (config.trendLag < 1 || config.trendLag > 5000) {
      throw const DailyIndicatorValidationException(
        'Trend lag must be between 1 and 5000 sessions.',
      );
    }
    if (config.rsiPeriod < 1 || config.rsiPeriod > 5000) {
      throw const DailyIndicatorValidationException(
        'RSI period must be between 1 and 5000 deltas.',
      );
    }
    if (config.adjustment == PriceAdjustment.unknown) {
      throw const DailyIndicatorValidationException(
        'Price adjustment must be known.',
      );
    }

    final dates = config.expectedSessionDates;
    if (dates == null) return;
    if (dates.isEmpty) {
      throw const DailyIndicatorValidationException(
        'Expected session dates must not be empty when supplied.',
      );
    }
    var previousDate = '';
    for (final date in dates) {
      _validateDate(date, 'Expected session date');
      if (date.compareTo(previousDate) <= 0) {
        throw const DailyIndicatorValidationException(
          'Expected session dates must be unique and strictly ascending.',
        );
      }
      previousDate = date;
    }
    if (dates.last != config.latestCompletedSessionDate) {
      throw const DailyIndicatorValidationException(
        'Expected session dates must end on the latest completed session.',
      );
    }
  }

  static void validateSeries({
    required DailyIndicatorConfig config,
    required List<MarketBar> bars,
  }) {
    validateConfig(config);
    String? previousDate;
    String? timezone;
    DailyIndicatorSessionDateSemantics? semantics;

    for (final bar in bars) {
      if (bar.symbol != config.symbol ||
          bar.provider != config.provider ||
          bar.feed != config.feed ||
          bar.adjustment != config.adjustment) {
        throw const DailyIndicatorValidationException(
          'All bars must share the configured symbol, provider, feed, and adjustment.',
        );
      }
      if (!bar.open.isFinite ||
          !bar.high.isFinite ||
          !bar.low.isFinite ||
          !bar.close.isFinite ||
          bar.open <= 0 ||
          bar.high <= 0 ||
          bar.low <= 0 ||
          bar.close <= 0 ||
          bar.low > bar.open ||
          bar.low > bar.close ||
          bar.high < bar.open ||
          bar.high < bar.close ||
          bar.low > bar.high ||
          bar.volume < 0) {
        throw const DailyIndicatorValidationException(
          'Bar OHLC values must be finite, positive, and consistent; volume must be non-negative.',
        );
      }
      if (bar.timestamp.toUtc().isAfter(config.analysisCutoff) ||
          bar.retrievedAt.toUtc().isAfter(config.analysisCutoff)) {
        throw const DailyIndicatorValidationException(
          'Bar source and retrieval timestamps must not be after the analysis cutoff.',
        );
      }
      if (bar.retrievedAt.toUtc().isBefore(bar.timestamp.toUtc())) {
        throw const DailyIndicatorValidationException(
          'Bar retrieval timestamp must not precede its source timestamp.',
        );
      }

      late final String sessionDate;
      late final DailyIndicatorSessionDateSemantics barSemantics;
      if (bar.tradingDate != null) {
        sessionDate = bar.tradingDate!;
        _validateDate(sessionDate, 'Bar trading date');
        final barTimezone = bar.exchangeTimezone;
        if (barTimezone == null || barTimezone.trim().isEmpty) {
          throw const DailyIndicatorValidationException(
            'An exchange trading date requires a non-empty exchange timezone.',
          );
        }
        if (barTimezone != barTimezone.trim()) {
          throw const DailyIndicatorValidationException(
            'Exchange timezone must not contain surrounding whitespace.',
          );
        }
        if (timezone != null && timezone != barTimezone) {
          throw const DailyIndicatorValidationException(
            'All exchange trading dates must use one consistent timezone.',
          );
        }
        timezone = barTimezone;
        barSemantics = DailyIndicatorSessionDateSemantics.exchangeTradingDate;
      } else {
        if (bar.exchangeTimezone != null) {
          throw const DailyIndicatorValidationException(
            'An exchange timezone requires an explicit trading date.',
          );
        }
        sessionDate = _dateFromUtc(bar.timestamp);
        barSemantics = DailyIndicatorSessionDateSemantics.utcDateProxy;
      }

      if (semantics != null && semantics != barSemantics) {
        throw const DailyIndicatorValidationException(
          'Bars must use one consistent session-date semantic.',
        );
      }
      semantics = barSemantics;
      if (previousDate != null && sessionDate.compareTo(previousDate) <= 0) {
        throw const DailyIndicatorValidationException(
          'Bar session dates must be unique and strictly ascending.',
        );
      }
      if (sessionDate.compareTo(config.latestCompletedSessionDate) > 0) {
        throw const DailyIndicatorValidationException(
          'Bars must not include a session after the latest completed session.',
        );
      }
      previousDate = sessionDate;
    }
  }

  static bool _isNormalizedSymbol(String symbol) =>
      symbol == symbol.trim().toUpperCase() &&
      RegExp(r'^[A-Z0-9.-]{1,15}$').hasMatch(symbol);

  static void _validateDate(String date, String label) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date)) {
      throw DailyIndicatorValidationException(
        '$label must use the YYYY-MM-DD format.',
      );
    }
    final year = int.parse(date.substring(0, 4));
    final month = int.parse(date.substring(5, 7));
    final day = int.parse(date.substring(8, 10));
    final parsed = DateTime.utc(year, month, day);
    if (year == 0 ||
        parsed.year != year ||
        parsed.month != month ||
        parsed.day != day) {
      throw DailyIndicatorValidationException('$label is not a real date.');
    }
  }
}

class DailyIndicatorValue<T> {
  DailyIndicatorValue._({
    required this.value,
    required this.unavailableReason,
    required this.formula,
    required Map<String, Object?> parameters,
    required this.units,
    required this.requiredSampleCount,
    required this.observedSampleCount,
    required this.staleSampleCount,
    required this.startSessionDate,
    required this.endSessionDate,
    required List<DateTime> retrievalTimes,
    required List<String> missingSessionDates,
  }) : parameters = Map<String, Object?>.unmodifiable(parameters),
       retrievalTimes = List<DateTime>.unmodifiable(retrievalTimes),
       missingSessionDates = List<String>.unmodifiable(missingSessionDates);

  final T? value;
  final DailyIndicatorUnavailableReason? unavailableReason;
  final String formula;
  final Map<String, Object?> parameters;
  final String units;
  final int requiredSampleCount;
  final int observedSampleCount;
  final int staleSampleCount;
  final String? startSessionDate;
  final String? endSessionDate;
  final List<DateTime> retrievalTimes;
  final List<String> missingSessionDates;

  bool get isAvailable => value != null && unavailableReason == null;

  Map<String, Object?> toJson() => {
    'availability': isAvailable ? 'available' : 'unavailable',
    'value': value is SessionColorSummary
        ? (value as SessionColorSummary).toJson()
        : value is SmaTrend
        ? (value as SmaTrend).toJson()
        : value,
    'unavailableReason': unavailableReason?.name,
    'formula': formula,
    'formulaVersion': dailyIndicatorFormulaVersion,
    'parameters': parameters,
    'units': units,
    'requiredSampleCount': requiredSampleCount,
    'observedSampleCount': observedSampleCount,
    'staleSampleCount': staleSampleCount,
    'startSessionDate': startSessionDate,
    'endSessionDate': endSessionDate,
    'retrievalTimes': retrievalTimes
        .map((time) => time.toUtc().toIso8601String())
        .toList(growable: false),
    'missingSessionDates': missingSessionDates,
  };
}

class SessionColorSummary {
  const SessionColorSummary({
    required this.greenCount,
    required this.redCount,
    required this.flatCount,
    required this.greenFraction,
    required this.redFraction,
    required this.flatFraction,
  });

  final int greenCount;
  final int redCount;
  final int flatCount;
  final double greenFraction;
  final double redFraction;
  final double flatFraction;

  Map<String, Object?> toJson() => {
    'greenCount': greenCount,
    'redCount': redCount,
    'flatCount': flatCount,
    'greenFraction': greenFraction,
    'redFraction': redFraction,
    'flatFraction': flatFraction,
  };
}

class DailyBarProvenance {
  const DailyBarProvenance({
    required this.sessionDate,
    required this.sourceTimestamp,
    required this.retrievedAt,
  });

  final String sessionDate;
  final DateTime sourceTimestamp;
  final DateTime retrievedAt;

  Map<String, Object?> toJson() => {
    'sessionDate': sessionDate,
    'sourceTimestamp': sourceTimestamp.toUtc().toIso8601String(),
    'retrievedAt': retrievedAt.toUtc().toIso8601String(),
  };
}

class DailyIndicatorCoverage {
  DailyIndicatorCoverage({
    required this.state,
    required this.expectedSessionCount,
    required this.observedExpectedSessionCount,
    required this.latestCompletedSessionPresent,
    required List<String>? expectedSessionDates,
    required List<String> missingExpectedSessionDates,
  }) : expectedSessionDates = expectedSessionDates == null
           ? null
           : List<String>.unmodifiable(expectedSessionDates),
       missingExpectedSessionDates = List<String>.unmodifiable(
         missingExpectedSessionDates,
       );

  final DailyIndicatorCoverageState state;
  final int? expectedSessionCount;
  final int observedExpectedSessionCount;
  final bool latestCompletedSessionPresent;
  final List<String>? expectedSessionDates;
  final List<String> missingExpectedSessionDates;

  double? get coverageFraction => expectedSessionCount == null
      ? null
      : observedExpectedSessionCount / expectedSessionCount!;

  Map<String, Object?> toJson() => {
    'state': state.name,
    'expectedSessionCount': expectedSessionCount,
    'observedExpectedSessionCount': observedExpectedSessionCount,
    'coverageFraction': coverageFraction,
    'latestCompletedSessionPresent': latestCompletedSessionPresent,
    'expectedSessionDates': expectedSessionDates,
    'missingExpectedSessionDates': missingExpectedSessionDates,
  };
}

class DailyIndicatorResult {
  DailyIndicatorResult({
    required this.symbol,
    required this.provider,
    required this.feed,
    required this.adjustment,
    required this.analysisCutoff,
    required this.latestCompletedSessionDate,
    required this.lookback,
    required this.maximumRetrievalAge,
    required this.sessionDateSemantics,
    required this.exchangeTimezone,
    required this.volumeScope,
    required this.corporateActionComparabilityConfirmed,
    required this.coverage,
    required this.sessionColors,
    required this.greenToRedRatio,
    required this.closeReturn,
    required this.simpleMovingAverage,
    required this.relativeVolume,
    this.trendLag = 1,
    this.rsiPeriod = 14,
    DailyIndicatorValue<SmaTrend>? smaTrend,
    DailyIndicatorValue<double>? exponentialMovingAverage,
    DailyIndicatorValue<double>? relativeStrengthIndex,
    required List<DailyBarProvenance> barProvenance,
    required List<String> limitations,
  }) : smaTrend =
           smaTrend ??
           _notCalculatedMetric<SmaTrend>(
             requiredSampleCount: lookback + trendLag,
             units: 'fraction',
           ),
       exponentialMovingAverage =
           exponentialMovingAverage ??
           _notCalculatedMetric<double>(
             requiredSampleCount: lookback,
             units: 'price',
           ),
       relativeStrengthIndex =
           relativeStrengthIndex ??
           _notCalculatedMetric<double>(
             requiredSampleCount: rsiPeriod + 1,
             units: 'index (0..100)',
           ),
       barProvenance = List<DailyBarProvenance>.unmodifiable(barProvenance),
       limitations = List<String>.unmodifiable(limitations);

  final String symbol;
  final MarketDataProvider provider;
  final MarketDataFeed feed;
  final PriceAdjustment adjustment;
  final DateTime analysisCutoff;
  final String latestCompletedSessionDate;
  final int lookback;
  final int trendLag;
  final int rsiPeriod;
  final Duration maximumRetrievalAge;
  final DailyIndicatorSessionDateSemantics? sessionDateSemantics;
  final String? exchangeTimezone;
  final String volumeScope;
  final bool corporateActionComparabilityConfirmed;
  final DailyIndicatorCoverage coverage;
  final DailyIndicatorValue<SessionColorSummary> sessionColors;
  final DailyIndicatorValue<double> greenToRedRatio;
  final DailyIndicatorValue<double> closeReturn;
  final DailyIndicatorValue<double> simpleMovingAverage;
  final DailyIndicatorValue<double> relativeVolume;
  final DailyIndicatorValue<SmaTrend> smaTrend;
  final DailyIndicatorValue<double> exponentialMovingAverage;
  final DailyIndicatorValue<double> relativeStrengthIndex;
  final List<DailyBarProvenance> barProvenance;
  final List<String> limitations;

  Map<String, Object?> toJson() => {
    'symbol': symbol,
    'provider': provider.name,
    'feed': feed.name,
    'adjustment': adjustment.name,
    'analysisCutoff': analysisCutoff.toUtc().toIso8601String(),
    'latestCompletedSessionDate': latestCompletedSessionDate,
    'lookback': lookback,
    'trendLag': trendLag,
    'rsiPeriod': rsiPeriod,
    'maximumRetrievalAgeSeconds': maximumRetrievalAge.inSeconds,
    'maximumRetrievalAgeMicroseconds': maximumRetrievalAge.inMicroseconds,
    'formulaVersion': dailyIndicatorFormulaVersion,
    'sessionDateSemantics': sessionDateSemantics?.name,
    'exchangeTimezone': exchangeTimezone,
    'volumeScope': volumeScope,
    'corporateActionComparabilityConfirmed':
        corporateActionComparabilityConfirmed,
    'coverage': coverage.toJson(),
    'limitations': limitations,
    'barProvenance': barProvenance.map((bar) => bar.toJson()).toList(),
    'sessionColors': sessionColors.toJson(),
    'greenToRedRatio': greenToRedRatio.toJson(),
    'closeReturn': closeReturn.toJson(),
    'simpleMovingAverage': simpleMovingAverage.toJson(),
    'relativeVolume': relativeVolume.toJson(),
    'smaTrend': smaTrend.toJson(),
    'exponentialMovingAverage': exponentialMovingAverage.toJson(),
    'relativeStrengthIndex': relativeStrengthIndex.toJson(),
  };
}

class DailyIndicatorEngine {
  const DailyIndicatorEngine._();

  static DailyIndicatorResult calculate({
    required DailyIndicatorConfig config,
    required List<MarketBar> bars,
  }) {
    final snapshot = List<MarketBar>.unmodifiable(bars);
    DailyIndicatorInputValidator.validateSeries(config: config, bars: snapshot);

    final datesByBar = <String, MarketBar>{};
    final semantics = snapshot.isEmpty
        ? null
        : snapshot.first.tradingDate == null
        ? DailyIndicatorSessionDateSemantics.utcDateProxy
        : DailyIndicatorSessionDateSemantics.exchangeTradingDate;
    for (final bar in snapshot) {
      datesByBar[_sessionDate(bar)] = bar;
    }

    final expectedDates = config.expectedSessionDates;
    final allMissing = expectedDates == null
        ? const <String>[]
        : expectedDates
              .where((date) => !datesByBar.containsKey(date))
              .toList(growable: false);
    final observedExpected = expectedDates == null
        ? 0
        : expectedDates.length - allMissing.length;
    final coverageState = snapshot.isEmpty
        ? DailyIndicatorCoverageState.empty
        : expectedDates == null
        ? DailyIndicatorCoverageState.unverified
        : allMissing.isEmpty
        ? DailyIndicatorCoverageState.complete
        : DailyIndicatorCoverageState.incomplete;
    final coverage = DailyIndicatorCoverage(
      state: coverageState,
      expectedSessionCount: expectedDates?.length,
      observedExpectedSessionCount: observedExpected,
      latestCompletedSessionPresent: datesByBar.containsKey(
        config.latestCompletedSessionDate,
      ),
      expectedSessionDates: expectedDates,
      missingExpectedSessionDates: allMissing,
    );

    final volumeScope = _volumeScope(config.provider, config.feed);
    final limitations = <String>[
      if (volumeScope == 'partial')
        'Volume is partial-feed volume; relative volume compares this same feed only, not consolidated market volume or liquidity.',
      if (volumeScope == 'completeButAccountCoverageUnverified')
        'Twelve Data end-of-day volume is documented as full-exchange volume and available after midnight ET on the next trading day; availability and historical depth still vary by instrument and account.',
      if (volumeScope == 'unsupported')
        'Volume scope is unknown or unsupported; volume-derived metrics are unavailable.',
      if (config.adjustment == PriceAdjustment.raw)
        'Raw prices are not established as corporate-action comparable.',
      'SMA, SMA trend, EMA and RSI describe arithmetic prices as supplied, including raw prices without a comparability gate; they are not economic metrics, and unverified corporate actions may distort them. Only closeReturn requires raw-price comparability confirmation.',
      'EMA and RSI use the entire supplied expected session history with earliest-date initialization, not a rolling reseed. Minimum initialization counts are not guarantees of convergence; results remain seed-dependent.',
      if (config.adjustment != PriceAdjustment.raw)
        'Adjusted prices are used as supplied; returns are arithmetic series returns, not verified total returns.',
      if (semantics == DailyIndicatorSessionDateSemantics.utcDateProxy)
        'Session dates are UTC-date proxies derived from source timestamps, not exchange-calendar dates.',
      if (semantics == DailyIndicatorSessionDateSemantics.exchangeTradingDate)
        'Exchange-provided tradingDate is used as supplied; no timezone conversion or exchange-calendar validation is inferred.',
    ];

    final colorWindow = _window(datesByBar, expectedDates, config.lookback);
    final returnWindow = _window(
      datesByBar,
      expectedDates,
      config.lookback + 1,
    );
    final volumeWindow = returnWindow;
    final colors = _metric<SessionColorSummary>(
      config: config,
      window: colorWindow,
      formula: 'green/red/flat counts over the last N sessions',
      parameters: {'N': config.lookback},
      units: 'count and fraction of N sessions',
      requiredSampleCount: config.lookback,
      hasAnyBars: snapshot.isNotEmpty,
      calculate: (window) {
        var green = 0;
        var red = 0;
        var flat = 0;
        for (final bar in window.bars) {
          if (bar.close > bar.open) {
            green++;
          } else if (bar.close < bar.open) {
            red++;
          } else {
            flat++;
          }
        }
        final total = config.lookback;
        return SessionColorSummary(
          greenCount: green,
          redCount: red,
          flatCount: flat,
          greenFraction: green / total,
          redFraction: red / total,
          flatFraction: flat / total,
        );
      },
    );
    final ratio = _metric<double>(
      config: config,
      window: colorWindow,
      formula: 'green session count / red session count',
      parameters: {'N': config.lookback},
      units: 'ratio',
      requiredSampleCount: config.lookback,
      hasAnyBars: snapshot.isNotEmpty,
      customUnavailable: colors.isAvailable && colors.value!.redCount == 0
          ? DailyIndicatorUnavailableReason.zeroDenominator
          : null,
      calculate: (_) => colors.isAvailable
          ? colors.value!.greenCount / colors.value!.redCount
          : double.nan,
    );
    final returns = _metric<double>(
      config: config,
      window: returnWindow,
      formula: 'close[t] / close[t-N] - 1',
      parameters: {'N': config.lookback},
      units: 'fraction',
      requiredSampleCount: config.lookback + 1,
      hasAnyBars: snapshot.isNotEmpty,
      customUnavailable:
          config.adjustment == PriceAdjustment.raw &&
              !config.corporateActionComparabilityConfirmed
          ? DailyIndicatorUnavailableReason.nonComparableRawPrices
          : null,
      calculate: (window) =>
          window.bars.last.close / window.bars.first.close - 1,
    );
    final sma = _metric<double>(
      config: config,
      window: colorWindow,
      formula: 'arithmetic mean of the last N closes',
      parameters: {'N': config.lookback},
      units: 'price',
      requiredSampleCount: config.lookback,
      hasAnyBars: snapshot.isNotEmpty,
      calculate: (window) => _scaledMean(window.bars.map((bar) => bar.close)),
    );
    final trend = _metric<SmaTrend>(
      config: config,
      window: _window(
        datesByBar,
        expectedDates,
        config.lookback + config.trendLag,
      ),
      formula: 'SMA[t] / SMA[t-K] - 1',
      parameters: {'N': config.lookback, 'K': config.trendLag},
      units: 'fraction',
      requiredSampleCount: config.lookback + config.trendLag,
      hasAnyBars: snapshot.isNotEmpty,
      calculate: (window) {
        final previous = _scaledMean(
          window.bars.take(config.lookback).map((bar) => bar.close),
        );
        final current = _scaledMean(
          window.bars.skip(config.trendLag).map((bar) => bar.close),
        );
        return SmaTrend(normalizedSlope: current / previous - 1);
      },
    );
    final ema = _metric<double>(
      config: config,
      window: _window(
        datesByBar,
        expectedDates,
        config.lookback,
        completeHistory: true,
      ),
      formula:
          'seed = mean(first N closes); EMA[t] = alpha*close[t] + (1-alpha)*EMA[t-1]',
      parameters: {
        'N': config.lookback,
        'alpha': 2 / (config.lookback + 1),
        'initialization': 'firstNCloseSma',
        'initializationSampleCount': config.lookback,
        'warmupSampleCount': config.lookback,
        'history': 'allExpectedSessions',
      },
      units: 'price',
      requiredSampleCount: config.lookback,
      hasAnyBars: snapshot.isNotEmpty,
      calculate: (window) {
        var value = _scaledMean(
          window.bars.take(config.lookback).map((bar) => bar.close),
        );
        final alpha = 2 / (config.lookback + 1);
        for (final bar in window.bars.skip(config.lookback)) {
          value = _blend(value, bar.close, alpha);
        }
        return value;
      },
    );
    final rsi = _metric<double>(
      config: config,
      window: _window(
        datesByBar,
        expectedDates,
        config.rsiPeriod + 1,
        completeHistory: true,
      ),
      formula:
          'seed = means of first P close gains/losses; Wilder mean[t] = (mean[t-1]*(P-1) + delta[t])/P; RSI = 100 - 100/(1 + avgGain/avgLoss)',
      parameters: {
        'P': config.rsiPeriod,
        'initialization': 'firstPDeltaMeans',
        'initializationDeltaCount': config.rsiPeriod,
        'initializationSampleCount': config.rsiPeriod + 1,
        'warmupSampleCount': config.rsiPeriod + 1,
        'history': 'allExpectedSessions',
        'flatValue': 50,
        'zeroLossValue': 100,
        'zeroGainValue': 0,
      },
      units: 'index (0..100)',
      requiredSampleCount: config.rsiPeriod + 1,
      hasAnyBars: snapshot.isNotEmpty,
      calculate: (window) => _wilderRsi(window.bars, config.rsiPeriod),
    );
    final relativeVolume = _metric<double>(
      config: config,
      window: volumeWindow,
      formula: 'volume[t] / mean(volume[t-N .. t-1])',
      parameters: {'N': config.lookback, 'latestExcludedFromBaseline': true},
      units: 'ratio',
      requiredSampleCount: config.lookback + 1,
      hasAnyBars: snapshot.isNotEmpty,
      customUnavailable: volumeScope == 'unsupported'
          ? DailyIndicatorUnavailableReason.unsupportedVolumeScope
          : null,
      calculate: (window) {
        final baseline = _scaledMean(
          window.bars.take(config.lookback).map((bar) => bar.volume.toDouble()),
        );
        if (baseline == 0) return double.nan;
        return window.bars.last.volume / baseline;
      },
    );

    return DailyIndicatorResult(
      symbol: config.symbol,
      provider: config.provider,
      feed: config.feed,
      adjustment: config.adjustment,
      analysisCutoff: config.analysisCutoff,
      latestCompletedSessionDate: config.latestCompletedSessionDate,
      lookback: config.lookback,
      trendLag: config.trendLag,
      rsiPeriod: config.rsiPeriod,
      maximumRetrievalAge: config.maximumRetrievalAge,
      sessionDateSemantics: semantics,
      exchangeTimezone: snapshot.isEmpty
          ? null
          : snapshot.first.exchangeTimezone,
      volumeScope: volumeScope,
      corporateActionComparabilityConfirmed:
          config.corporateActionComparabilityConfirmed,
      coverage: coverage,
      sessionColors: colors,
      greenToRedRatio: ratio,
      closeReturn: returns,
      simpleMovingAverage: sma,
      smaTrend: trend,
      exponentialMovingAverage: ema,
      relativeStrengthIndex: rsi,
      relativeVolume: relativeVolume,
      barProvenance: snapshot
          .map(
            (bar) => DailyBarProvenance(
              sessionDate: _sessionDate(bar),
              sourceTimestamp: bar.timestamp.toUtc(),
              retrievedAt: bar.retrievedAt.toUtc(),
            ),
          )
          .toList(growable: false),
      limitations: limitations,
    );
  }
}

class _MetricWindow {
  const _MetricWindow({
    required this.requiredDates,
    required this.bars,
    required this.missingDates,
    required this.hasEnoughExpectedDates,
  });

  final List<String> requiredDates;
  final List<MarketBar> bars;
  final List<String> missingDates;
  final bool hasEnoughExpectedDates;
}

_MetricWindow _window(
  Map<String, MarketBar> bars,
  List<String>? expectedDates,
  int requiredCount, {
  bool completeHistory = false,
}) {
  if (expectedDates == null) {
    return _MetricWindow(
      requiredDates: const [],
      bars: const [],
      missingDates: const [],
      hasEnoughExpectedDates: false,
    );
  }
  if (expectedDates.length < requiredCount) {
    return _MetricWindow(
      requiredDates: expectedDates,
      bars: expectedDates
          .map((date) => bars[date])
          .whereType<MarketBar>()
          .toList(),
      missingDates: expectedDates
          .where((date) => !bars.containsKey(date))
          .toList(),
      hasEnoughExpectedDates: false,
    );
  }
  final requiredDates = expectedDates
      .skip(completeHistory ? 0 : expectedDates.length - requiredCount)
      .toList(growable: false);
  final matchingBars = <MarketBar>[];
  final missing = <String>[];
  for (final date in requiredDates) {
    final bar = bars[date];
    if (bar == null) {
      missing.add(date);
    } else {
      matchingBars.add(bar);
    }
  }
  return _MetricWindow(
    requiredDates: requiredDates,
    bars: matchingBars,
    missingDates: missing,
    hasEnoughExpectedDates: true,
  );
}

DailyIndicatorValue<T> _metric<T>({
  required DailyIndicatorConfig config,
  required _MetricWindow window,
  required String formula,
  required Map<String, Object?> parameters,
  required String units,
  required int requiredSampleCount,
  required bool hasAnyBars,
  required T Function(_MetricWindow window) calculate,
  DailyIndicatorUnavailableReason? customUnavailable,
}) {
  final staleBars = window.bars
      .where((bar) {
        final age = config.analysisCutoff.difference(bar.retrievedAt.toUtc());
        return age > config.maximumRetrievalAge;
      })
      .toList(growable: false);
  final missingCount = window.missingDates.length;
  DailyIndicatorUnavailableReason? unavailable;
  if (!hasAnyBars) {
    unavailable = DailyIndicatorUnavailableReason.insufficientData;
  } else if (config.expectedSessionDates == null) {
    unavailable = DailyIndicatorUnavailableReason.coverageUnverified;
  } else if (!window.hasEnoughExpectedDates) {
    unavailable = DailyIndicatorUnavailableReason.insufficientData;
  } else if (missingCount > 0) {
    unavailable = DailyIndicatorUnavailableReason.incompleteCoverage;
  } else if (staleBars.isNotEmpty) {
    unavailable = DailyIndicatorUnavailableReason.staleData;
  } else if (customUnavailable != null) {
    unavailable = customUnavailable;
  }

  T? value;
  if (unavailable == null) {
    final calculated = calculate(window);
    final numeric = calculated is double
        ? calculated
        : calculated is SmaTrend
        ? calculated.normalizedSlope
        : null;
    if (numeric != null && !numeric.isFinite) {
      unavailable = numeric.isNaN
          ? DailyIndicatorUnavailableReason.zeroDenominator
          : DailyIndicatorUnavailableReason.numericalOverflow;
    } else {
      value = calculated;
    }
  }

  final requiredDates = window.requiredDates;
  return DailyIndicatorValue<T>._(
    value: value,
    unavailableReason: unavailable,
    formula: formula,
    parameters: parameters,
    units: units,
    requiredSampleCount: requiredSampleCount,
    observedSampleCount: window.bars.length,
    staleSampleCount: staleBars.length,
    startSessionDate: requiredDates.isEmpty ? null : requiredDates.first,
    endSessionDate: requiredDates.isEmpty ? null : requiredDates.last,
    retrievalTimes: window.bars
        .map((bar) => bar.retrievedAt.toUtc())
        .toList(growable: false),
    missingSessionDates: window.missingDates,
  );
}

DailyIndicatorValue<T> _notCalculatedMetric<T>({
  required int requiredSampleCount,
  required String units,
}) => DailyIndicatorValue<T>._(
  value: null,
  unavailableReason: DailyIndicatorUnavailableReason.insufficientData,
  formula: 'not calculated by this result constructor',
  parameters: const {},
  units: units,
  requiredSampleCount: requiredSampleCount,
  observedSampleCount: 0,
  staleSampleCount: 0,
  startSessionDate: null,
  endSessionDate: null,
  retrievalTimes: const [],
  missingSessionDates: const [],
);

// Convex interpolation avoids overflowing the sum of weighted large prices.
double _blend(double previous, double next, double weight) => weight == 1
    ? next
    : next >= previous
    ? previous + (next - previous) * weight
    : previous - (previous - next) * weight;

double _wilderRsi(List<MarketBar> bars, int period) {
  final gains = <double>[];
  final losses = <double>[];
  for (var i = 1; i <= period; i++) {
    final delta = bars[i].close - bars[i - 1].close;
    gains.add(math.max(delta, 0));
    losses.add(math.max(-delta, 0));
  }
  var averageGain = _scaledMean(gains);
  var averageLoss = _scaledMean(losses);
  for (var i = period + 1; i < bars.length; i++) {
    final delta = bars[i].close - bars[i - 1].close;
    averageGain = _blend(averageGain, math.max(delta, 0), 1 / period);
    averageLoss = _blend(averageLoss, math.max(-delta, 0), 1 / period);
  }
  if (averageGain == 0 && averageLoss == 0) return 50;
  if (averageLoss == 0) return 100;
  if (averageGain == 0) return 0;
  // Scale before adding gains/losses or dividing their ratio.
  final scale = math.max(averageGain, averageLoss);
  final gain = averageGain / scale;
  final loss = averageLoss / scale;
  return 100 * (gain / (gain + loss));
}

double _scaledMean(Iterable<double> values) {
  final materialized = values.toList(growable: false);
  if (materialized.isEmpty) return double.nan;
  var scale = 0.0;
  for (final value in materialized) {
    scale = math.max(scale, value);
  }
  if (scale == 0) return 0;

  var sum = 0.0;
  var compensation = 0.0;
  for (final value in materialized) {
    final adjusted = value / scale - compensation;
    final next = sum + adjusted;
    compensation = (next - sum) - adjusted;
    sum = next;
  }
  final mean = scale * (sum / materialized.length);
  return mean.isFinite ? mean : double.infinity;
}

String _volumeScope(MarketDataProvider provider, MarketDataFeed feed) {
  if (provider == MarketDataProvider.alpaca && feed == MarketDataFeed.iex) {
    return 'partial';
  }
  if (provider == MarketDataProvider.twelveData &&
      feed == MarketDataFeed.endOfDay) {
    return 'completeButAccountCoverageUnverified';
  }
  return 'unsupported';
}

String _sessionDate(MarketBar bar) =>
    bar.tradingDate ?? _dateFromUtc(bar.timestamp);

String _dateFromUtc(DateTime date) {
  final utc = date.toUtc();
  return '${utc.year.toString().padLeft(4, '0')}-'
      '${utc.month.toString().padLeft(2, '0')}-'
      '${utc.day.toString().padLeft(2, '0')}';
}
