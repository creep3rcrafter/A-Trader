import 'package:a_trade/market_data/daily_indicators.dart';

Map<String, Object?> indicatorCardFixture({String symbol = 'SOFI'}) {
  Map<String, Object?> metric(
    Object? value,
    String units, {
    String? reason,
    int required = 20,
  }) => {
    'availability': reason == null ? 'available' : 'unavailable',
    'value': value,
    'unavailableReason': reason,
    'formula': 'SYNTHETIC FIXTURE ONLY',
    'formulaVersion': dailyIndicatorFormulaVersion,
    'parameters': {'lookback': 20},
    'units': units,
    'requiredSampleCount': required,
    'observedSampleCount': required,
    'staleSampleCount': 0,
    'startSessionDate': '2026-09-01',
    'endSessionDate': '2026-10-09',
    'retrievalTimes': List.filled(required, '2026-10-12T08:00:00Z'),
    'missingSessionDates': <String>[],
  };
  return {
    'status': 'ok',
    'coverage': 'Synthetic fixture only',
    'limitations': ['SYNTHETIC TEST FIXTURE - not live market data.'],
    'sources': [
      {
        'title': 'Synthetic fixture bars',
        'url': 'https://data.alpaca.markets/v2/stocks/$symbol/bars?feed=iex',
        'publishedAt': '2026-10-09',
        'retrievedAt': '2026-10-12T08:00:00Z',
      },
    ],
    'data': {
      'symbol': symbol,
      'provider': 'alpaca',
      'feed': 'iex',
      'adjustment': 'raw',
      'analysisCutoff': '2026-10-12T08:00:01Z',
      'latestCompletedSessionDate': '2026-10-09',
      'lookback': 20,
      'trendLag': 1,
      'rsiPeriod': 14,
      'formulaVersion': dailyIndicatorFormulaVersion,
      'corporateActionComparabilityConfirmed': false,
      'volumeScope': 'partial',
      'coverage': {'state': 'complete'},
      'limitations': ['Raw-price corporate actions unverified.'],
      'barProvenance': [
        for (var day = 1; day <= 25; day++)
          {
            'sessionDate': '2026-09-${day.toString().padLeft(2, '0')}',
            'sourceTimestamp':
                '2026-09-${day.toString().padLeft(2, '0')}T04:00:00Z',
            'retrievedAt': '2026-10-12T08:00:00Z',
          },
        {
          'sessionDate': '2026-10-09',
          'sourceTimestamp': '2026-10-09T04:00:00Z',
          'retrievedAt': '2026-10-12T08:00:00Z',
        },
      ],
      'sessionColors': metric({
        'greenCount': 12,
        'redCount': 6,
        'flatCount': 2,
        'greenFraction': 0.6,
        'redFraction': 0.3,
        'flatFraction': 0.1,
      }, 'count and fraction of N sessions'),
      'greenToRedRatio': metric(2.0, 'ratio'),
      'closeReturn': metric(
        null,
        'fraction',
        reason: 'nonComparableRawPrices',
        required: 21,
      ),
      'simpleMovingAverage': metric(7.5, 'price'),
      'relativeVolume': metric(1.25, 'ratio', required: 21),
      'smaTrend': metric(
        {'slope': 0.01, 'direction': 'rising'},
        'fraction',
        required: 21,
      ),
      'exponentialMovingAverage': metric(7.75, 'price'),
      'relativeStrengthIndex': metric(62.5, 'index (0..100)', required: 15),
    },
  };
}
