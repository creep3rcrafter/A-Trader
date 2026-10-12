import 'daily_indicators.dart';
import 'market_data.dart';

class IndicatorMetricSnapshot {
  const IndicatorMetricSnapshot({
    required this.value,
    required this.reason,
    required this.units,
    required this.requiredSamples,
    required this.observedSamples,
  });

  final Object? value;
  final DailyIndicatorUnavailableReason? reason;
  final String units;
  final int requiredSamples;
  final int observedSamples;
  bool get isAvailable => reason == null;
}

class IndicatorSourceSnapshot {
  const IndicatorSourceSnapshot(this.url, this.date, this.retrievedAt);
  final Uri url;
  final String date;
  final DateTime retrievedAt;
}

class IndicatorSnapshot {
  IndicatorSnapshot({
    required this.symbol,
    required this.provider,
    required this.feed,
    required this.cutoff,
    required this.lastSession,
    required this.lookback,
    required this.version,
    required this.volumeScope,
    required this.coverage,
    required Map<String, IndicatorMetricSnapshot> metrics,
    required List<String> limitations,
    required List<IndicatorSourceSnapshot> sources,
  }) : metrics = Map.unmodifiable(metrics),
       limitations = List.unmodifiable(limitations),
       sources = List.unmodifiable(sources);

  final String symbol;
  final MarketDataProvider? provider;
  final MarketDataFeed? feed;
  final DateTime? cutoff;
  final String? lastSession;
  final int? lookback;
  final String? version;
  final String? volumeScope;
  final DailyIndicatorCoverageState? coverage;
  final Map<String, IndicatorMetricSnapshot> metrics;
  final List<String> limitations;
  final List<IndicatorSourceSnapshot> sources;

  static const metricUnits = {
    'sessionColors': 'count and fraction of N sessions',
    'greenToRedRatio': 'ratio',
    'closeReturn': 'fraction',
    'simpleMovingAverage': 'price',
    'relativeVolume': 'ratio',
    'smaTrend': 'fraction',
    'exponentialMovingAverage': 'price',
    'relativeStrengthIndex': 'index (0..100)',
  };

  static IndicatorSnapshot parse(Map<String, dynamic> json, String symbol) {
    final limitations = _strings(json['limitations'], maximum: 30);
    if (json['status'] == 'unavailable') {
      if (json['data'] != null ||
          json['sources'] is! List ||
          (json['sources'] as List).isNotEmpty ||
          limitations.isEmpty) {
        throw const FormatException();
      }
      return IndicatorSnapshot(
        symbol: symbol,
        provider: null,
        feed: null,
        cutoff: null,
        lastSession: null,
        lookback: null,
        version: null,
        volumeScope: null,
        coverage: null,
        metrics: {},
        limitations: limitations,
        sources: [],
      );
    }
    if (json['status'] != 'ok') throw const FormatException();
    final data = _map(json['data']);
    final provider = _enum(data['provider'], MarketDataProvider.values);
    final feed = _enum(data['feed'], MarketDataFeed.values);
    if (data['symbol'] != symbol ||
        !(provider == MarketDataProvider.alpaca && feed == MarketDataFeed.iex ||
            provider == MarketDataProvider.twelveData &&
                feed == MarketDataFeed.endOfDay) ||
        data['adjustment'] != 'raw' ||
        data['formulaVersion'] != dailyIndicatorFormulaVersion ||
        data['lookback'] != 20 ||
        data['trendLag'] != 1 ||
        data['rsiPeriod'] != 14 ||
        data['corporateActionComparabilityConfirmed'] != false ||
        data['volumeScope'] !=
            (provider == MarketDataProvider.alpaca
                ? 'partial'
                : 'completeButAccountCoverageUnverified')) {
      throw const FormatException();
    }
    final cutoff = _time(data['analysisCutoff']);
    final last = _date(data['latestCompletedSessionDate']);
    if (DateTime.parse(last).isAfter(cutoff)) throw const FormatException();
    final coverage = _enum(
      _map(data['coverage'])['state'],
      DailyIndicatorCoverageState.values,
    );
    final metrics = <String, IndicatorMetricSnapshot>{};
    for (final entry in metricUnits.entries) {
      final metric = _map(data[entry.key]);
      final units = metric['units'];
      if (units != entry.value ||
          metric['formulaVersion'] != dailyIndicatorFormulaVersion ||
          metric['formula'] is! String ||
          (metric['formula'] as String).isEmpty ||
          metric['parameters'] is! Map<String, dynamic>) {
        throw const FormatException();
      }
      final required = _count(metric['requiredSampleCount']);
      final observed = _count(metric['observedSampleCount']);
      final stale = _count(metric['staleSampleCount']);
      final expectedRequired = switch (entry.key) {
        'closeReturn' || 'relativeVolume' || 'smaTrend' => 21,
        'relativeStrengthIndex' => 15,
        _ => 20,
      };
      final recursive =
          entry.key == 'exponentialMovingAverage' ||
          entry.key == 'relativeStrengthIndex';
      if (required != expectedRequired || (!recursive && observed > required)) {
        throw const FormatException();
      }
      if (stale > observed) throw const FormatException();
      for (final boundary in ['startSessionDate', 'endSessionDate']) {
        if (metric[boundary] != null &&
            _date(metric[boundary]).compareTo(last) > 0) {
          throw const FormatException();
        }
      }
      final missing = _strings(metric['missingSessionDates'], maximum: 120);
      for (final date in missing) {
        _date(date);
      }
      final times = metric['retrievalTimes'];
      if (times is! List || times.length > 120 || times.length != observed) {
        throw const FormatException();
      }
      for (final time in times) {
        if (_time(time).isAfter(cutoff)) throw const FormatException();
      }
      final available = metric['availability'] == 'available';
      if (!available && metric['availability'] != 'unavailable') {
        throw const FormatException();
      }
      final reason = available
          ? null
          : _enum(
              metric['unavailableReason'],
              DailyIndicatorUnavailableReason.values,
            );
      Object? value;
      if (available) {
        if (metric['unavailableReason'] != null ||
            observed < required ||
            stale != 0 ||
            missing.isNotEmpty) {
          throw const FormatException();
        }
        if (entry.key == 'sessionColors') {
          final colors = _map(metric['value']);
          final green = _count(colors['greenCount']);
          final red = _count(colors['redCount']);
          final flat = _count(colors['flatCount']);
          if (green + red + flat != 20) throw const FormatException();
          for (final pair in [
            ('greenFraction', green),
            ('redFraction', red),
            ('flatFraction', flat),
          ]) {
            if ((_number(colors[pair.$1]) - pair.$2 / 20).abs() > 1e-10) {
              throw const FormatException();
            }
          }
          value = SessionColorSummary(
            greenCount: green,
            redCount: red,
            flatCount: flat,
            greenFraction: green / 20,
            redFraction: red / 20,
            flatFraction: flat / 20,
          );
        } else if (entry.key == 'smaTrend') {
          final trend = _map(metric['value']);
          final slope = _number(trend['slope']);
          final direction = slope > 0
              ? 'rising'
              : slope < 0
              ? 'falling'
              : 'flat';
          if (trend['direction'] != direction) throw const FormatException();
          value = Map<String, Object>.unmodifiable({
            'slope': slope,
            'direction': direction,
          });
        } else {
          final number = _number(metric['value']);
          if (entry.key == 'relativeStrengthIndex' &&
                  (number < 0 || number > 100) ||
              ['relativeVolume', 'greenToRedRatio'].contains(entry.key) &&
                  number < 0 ||
              [
                    'simpleMovingAverage',
                    'exponentialMovingAverage',
                  ].contains(entry.key) &&
                  number <= 0 ||
              entry.key == 'closeReturn') {
            // Raw return cannot be available without confirmed comparability.
            throw const FormatException();
          }
          value = number;
        }
      } else if (metric['value'] != null) {
        throw const FormatException();
      }
      metrics[entry.key] = IndicatorMetricSnapshot(
        value: value,
        reason: reason,
        units: entry.value,
        requiredSamples: required,
        observedSamples: observed,
      );
    }
    final sources = json['sources'];
    if (sources is! List || sources.length > 2) throw const FormatException();
    final provenance = data['barProvenance'];
    if (provenance is! List || provenance.length > 120) {
      throw const FormatException();
    }
    var previousDate = '';
    final actualDates = <String>{};
    for (final raw in provenance) {
      final bar = _map(raw);
      final date = _date(bar['sessionDate']);
      final sourceAt = _time(bar['sourceTimestamp']);
      final retrievedAt = _time(bar['retrievedAt']);
      if (date.compareTo(previousDate) <= 0 ||
          date.compareTo(last) > 0 ||
          retrievedAt.isAfter(cutoff) ||
          sourceAt.isAfter(retrievedAt)) {
        throw const FormatException();
      }
      previousDate = date;
      actualDates.add(date);
    }
    if (metrics.values.any((metric) => metric.isAvailable) &&
        (provenance.isEmpty || sources.isEmpty)) {
      throw const FormatException();
    }
    final parsedSources = <IndicatorSourceSnapshot>[];
    for (final raw in sources) {
      final source = _map(raw);
      final uri = source['url'] is String
          ? Uri.tryParse(source['url'] as String)
          : null;
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.port != 443 ||
          uri.userInfo.isNotEmpty ||
          uri.hasFragment ||
          !(provider == MarketDataProvider.alpaca &&
                  uri.host == 'data.alpaca.markets' &&
                  uri.path == '/v2/stocks/$symbol/bars' &&
                  uri.queryParameters['feed'] == 'iex' ||
              provider == MarketDataProvider.twelveData &&
                  uri.host == 'api.twelvedata.com' &&
                  uri.path == '/time_series' &&
                  uri.queryParameters['symbol'] == symbol) ||
          uri.queryParameters.keys.any(
            (key) => key.toLowerCase().contains('key'),
          )) {
        throw const FormatException();
      }
      final retrieved = _time(source['retrievedAt']);
      if (retrieved.isAfter(cutoff)) throw const FormatException();
      final date = _date(source['publishedAt']);
      if (!actualDates.contains(date)) throw const FormatException();
      parsedSources.add(IndicatorSourceSnapshot(uri, date, retrieved));
    }
    return IndicatorSnapshot(
      symbol: symbol,
      provider: provider,
      feed: feed,
      cutoff: cutoff,
      lastSession: last,
      lookback: 20,
      version: dailyIndicatorFormulaVersion,
      volumeScope: data['volumeScope'] as String,
      coverage: coverage,
      metrics: metrics,
      limitations: [
        ...limitations,
        ..._strings(data['limitations'], maximum: 30),
      ],
      sources: parsedSources,
    );
  }
}

Map<String, dynamic> _map(Object? value) {
  if (value is! Map<String, dynamic>) throw const FormatException();
  return value;
}

T _enum<T extends Enum>(Object? value, List<T> values) {
  for (final entry in values) {
    if (entry.name == value) return entry;
  }
  throw const FormatException();
}

int _count(Object? value) {
  if (value is! int || value < 0 || value > 5001) throw const FormatException();
  return value;
}

double _number(Object? value) {
  if (value is! num || !value.toDouble().isFinite) {
    throw const FormatException();
  }
  return value.toDouble();
}

List<String> _strings(Object? value, {required int maximum}) {
  if (value is! List || value.length > maximum) throw const FormatException();
  return [
    for (final entry in value)
      if (entry is String && entry.length <= 2000)
        entry
      else
        throw const FormatException(),
  ];
}

String _date(Object? value) {
  if (value is! String ||
      !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value) ||
      DateTime.tryParse(value)?.toIso8601String().substring(0, 10) != value) {
    throw const FormatException();
  }
  return value;
}

DateTime _time(Object? value) {
  if (value is! String ||
      !RegExp(
        r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$',
      ).hasMatch(value)) {
    throw const FormatException();
  }
  _date(value.substring(0, 10));
  if (int.parse(value.substring(11, 13)) > 23 ||
      int.parse(value.substring(14, 16)) > 59 ||
      int.parse(value.substring(17, 19)) > 59) {
    throw const FormatException();
  }
  if (!value.endsWith('Z')) {
    final offset = value.substring(value.length - 5);
    if (int.parse(offset.substring(0, 2)) > 23 ||
        int.parse(offset.substring(3, 5)) > 59) {
      throw const FormatException();
    }
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) throw const FormatException();
  return parsed.toUtc();
}
