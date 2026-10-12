import 'package:flutter/material.dart';

import 'local_market_data_service.dart';
import 'market_data.dart';
import 'daily_indicators.dart';
import 'indicator_snapshot.dart';
import '../providers/assistant_service.dart';

const temporaryStocks = <(String, String)>[
  ('SOFI', 'SoFi Technologies'),
  ('RKLB', 'Rocket Lab'),
  ('BBAI', 'BigBear.ai'),
  ('MVIS', 'MicroVision'),
  ('OCGN', 'Ocugen'),
  ('SENS', 'Senseonics'),
  ('GEVO', 'Gevo'),
  ('FCEL', 'FuelCell Energy'),
  ('ONDS', 'Ondas Holdings'),
  ('KULR', 'KULR Technology Group'),
];

class LiveIdeasView extends StatefulWidget {
  const LiveIdeasView({
    required this.backendUrl,
    required this.service,
    required this.savedTickers,
    required this.savedOnly,
    required this.onToggleSaved,
    this.assistantService,
    this.analysisPrompt = '',
    this.holdingDays = 10,
    super.key,
  });

  final String backendUrl;
  final LocalMarketDataService service;
  final Set<String> savedTickers;
  final bool savedOnly;
  final ValueChanged<String> onToggleSaved;
  final AssistantService? assistantService;
  final String analysisPrompt;
  final int holdingDays;

  @override
  State<LiveIdeasView> createState() => _LiveIdeasViewState();
}

class _LiveIdeasViewState extends State<LiveIdeasView> {
  final Map<String, QuoteSnapshot> _quotes = {};
  final Map<String, String> _errors = {};
  int _generation = 0;
  bool _loading = false;
  final Map<String, AssistantExplanation> _explanations = {};
  final Map<String, String> _analysisErrors = {};
  final Set<String> _analyzing = {};
  int _analysisGeneration = 0;
  final Map<String, IndicatorSnapshot> _indicators = {};
  final Map<String, String> _indicatorErrors = {};
  final Set<String> _loadingIndicators = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(LiveIdeasView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.backendUrl != widget.backendUrl ||
        oldWidget.service != widget.service) {
      _load();
    } else if (oldWidget.analysisPrompt != widget.analysisPrompt ||
        oldWidget.holdingDays != widget.holdingDays ||
        oldWidget.assistantService != widget.assistantService) {
      _clearAnalysis();
    }
  }

  @override
  void dispose() {
    _generation++;
    _analysisGeneration++;
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final service = widget.service;
    final backendUrl = widget.backendUrl;
    setState(() {
      _loading = true;
      _quotes.clear();
      _errors.clear();
      _indicators.clear();
      _indicatorErrors.clear();
      _loadingIndicators.clear();
      _clearAnalysis();
    });
    var twelveData = false;
    for (var index = 0; index < temporaryStocks.length; index++) {
      if (twelveData && index > 0) {
        // Stay below the server's conservative seven-credit rolling minute.
        await Future<void>.delayed(const Duration(seconds: 11));
      }
      if (!mounted || generation != _generation) return;
      final ticker = temporaryStocks[index].$1;
      try {
        final result = await service.quote(backendUrl, ticker);
        if (!mounted || generation != _generation) return;
        twelveData = result.quote.provider == MarketDataProvider.twelveData;
        setState(() => _quotes[ticker] = result);
      } on LocalMarketDataException catch (error) {
        if (!mounted || generation != _generation) return;
        setState(() => _errors[ticker] = error.message);
        // A quota or configuration failure should not trigger nine more calls.
        if (error.message != 'No market data is available for this ticker.') {
          setState(() {
            for (final stock in temporaryStocks.skip(index + 1)) {
              _errors[stock.$1] = 'Not requested: ${error.message}';
            }
          });
          break;
        }
      }
    }
    if (mounted && generation == _generation) {
      setState(() => _loading = false);
    }
  }

  void _clearAnalysis() {
    _analysisGeneration++;
    _explanations.clear();
    _analysisErrors.clear();
    _analyzing.clear();
  }

  Future<void> _loadIndicators(String ticker) async {
    if (_loading || _loadingIndicators.isNotEmpty || _analyzing.isNotEmpty) {
      return;
    }
    final generation = _generation;
    setState(() {
      _loadingIndicators.add(ticker);
      _indicators.remove(ticker);
      _indicatorErrors.remove(ticker);
    });
    try {
      final result = await widget.service.indicators(widget.backendUrl, ticker);
      if (!mounted || generation != _generation) return;
      setState(() => _indicators[ticker] = result);
    } on LocalMarketDataException catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() => _indicatorErrors[ticker] = error.message);
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loadingIndicators.remove(ticker));
      }
    }
  }

  Future<void> _explain(String ticker, {bool research = false}) async {
    final service = widget.assistantService;
    if (service == null ||
        _analyzing.isNotEmpty ||
        _loadingIndicators.isNotEmpty ||
        _loading) {
      return;
    }
    final generation = _analysisGeneration;
    setState(() {
      _analyzing.add(ticker);
      _explanations.remove(ticker);
      _analysisErrors.remove(ticker);
    });
    try {
      final result = research
          ? await service.research(
              widget.backendUrl,
              ticker,
              widget.analysisPrompt,
              holdingDays: widget.holdingDays,
            )
          : await service.explain(
              widget.backendUrl,
              ticker,
              widget.analysisPrompt,
            );
      if (!mounted || generation != _analysisGeneration) return;
      setState(() => _explanations[ticker] = result);
    } on AssistantException catch (error) {
      if (!mounted || generation != _analysisGeneration) return;
      setState(() => _analysisErrors[ticker] = error.message);
    } finally {
      if (mounted && generation == _analysisGeneration) {
        setState(() => _analyzing.remove(ticker));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final stocks = temporaryStocks
        .where(
          (stock) =>
              !widget.savedOnly || widget.savedTickers.contains(stock.$1),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Temporary watchlist · real provider quotes, not trade recommendations. '
          'These ten stocks are not ranked or screened for microcap eligibility. '
          'Entry, stop-loss and screened recommendations are not available yet. '
          'Ask AI explains quote limitations only; it is not a verified trading plan.',
        ),
        const SizedBox(height: 8),
        const Text(
          'Latest available prices may be stale when markets are closed. '
          'Partial feeds are not consolidated market prices. Twelve Data remains '
          'personal research/testing only; loading is paced to conserve its free quota. '
          'Saved stocks are kept only for this session.',
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const Key('refresh_ideas'),
          onPressed:
              _loading || _analyzing.isNotEmpty || _loadingIndicators.isNotEmpty
              ? null
              : _load,
          icon: const Icon(Icons.refresh),
          label: Text(_loading ? 'Loading quotes...' : 'Refresh quotes'),
        ),
        if (_loading) const LinearProgressIndicator(),
        if (stocks.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'No saved stocks yet. Use a stock bookmark to save it here.',
            ),
          ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth > 760
                ? (constraints.maxWidth - 16) / 2
                : constraints.maxWidth;
            return Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                for (final stock in stocks)
                  SizedBox(width: width, child: _stockCard(context, stock)),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _stockCard(BuildContext context, (String, String) stock) {
    final ticker = stock.$1;
    final snapshot = _quotes[ticker];
    final quote = snapshot?.quote;
    final error = _errors[ticker];
    final saved = widget.savedTickers.contains(ticker);
    final theme = Theme.of(context);
    return Card(
      key: Key('idea_$ticker'),
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(ticker, style: theme.textTheme.titleLarge),
                ),
                IconButton(
                  key: Key('save_$ticker'),
                  tooltip: saved ? 'Remove saved stock' : 'Save stock',
                  onPressed: () => widget.onToggleSaved(ticker),
                  icon: Icon(saved ? Icons.bookmark : Icons.bookmark_border),
                ),
              ],
            ),
            Text(stock.$2),
            const SizedBox(height: 10),
            if (quote != null) ...[
              Text(
                quote.lastPrice == null
                    ? 'Last price unavailable'
                    : '\$${quote.lastPrice!.toStringAsFixed(4)}',
                key: Key('price_$ticker'),
                style: theme.textTheme.headlineSmall,
              ),
              Text('${quote.provider.name} / ${quote.feed.name}'),
              Text(
                'Trade time (UTC): ${quote.lastTradeAt?.toIso8601String() ?? 'Unavailable'}',
              ),
              Text(
                'Freshness: ${quote.freshnessAt(now: DateTime.now().toUtc(), maximumAge: const Duration(minutes: 1)).name}',
              ),
              ExpansionTile(
                key: Key('details_$ticker'),
                tilePadding: EdgeInsets.zero,
                title: const Text('Quote details & coverage'),
                children: [
                  Text(
                    'Bid: ${_price(quote.bidPrice)} / Ask: ${_price(quote.askPrice)}',
                  ),
                  Text(
                    'Quote time (UTC): ${quote.quoteAt?.toIso8601String() ?? 'Unavailable'}',
                  ),
                  Text(
                    'Retrieved (UTC): ${quote.retrievedAt.toIso8601String()}',
                  ),
                  Text('Freshness at retrieval: ${snapshot!.freshness.name}'),
                  Text(marketCoverage(quote.provider)),
                ],
              ),
              OutlinedButton.icon(
                key: Key('indicators_$ticker'),
                onPressed:
                    _loading ||
                        _loadingIndicators.isNotEmpty ||
                        _analyzing.isNotEmpty
                    ? null
                    : () => _loadIndicators(ticker),
                icon: const Icon(Icons.calculate_outlined),
                label: Text(
                  _loadingIndicators.contains(ticker)
                      ? 'Calculating indicators...'
                      : 'Calculate daily indicators',
                ),
              ),
              if (_indicatorErrors[ticker] case final indicatorError?)
                Text(
                  indicatorError,
                  key: Key('indicator_error_$ticker'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              if (_indicators[ticker] case final indicators?)
                _indicatorDetails(ticker, indicators),
              if (widget.assistantService != null)
                OutlinedButton.icon(
                  key: Key('research_ai_$ticker'),
                  onPressed:
                      _analyzing.isNotEmpty ||
                          _loading ||
                          _loadingIndicators.isNotEmpty
                      ? null
                      : () => _explain(ticker, research: true),
                  icon: const Icon(Icons.manage_search),
                  label: const Text('Research with local tools'),
                ),
              if (widget.assistantService != null)
                OutlinedButton.icon(
                  key: Key('ask_ai_$ticker'),
                  onPressed:
                      _analyzing.isNotEmpty ||
                          _loading ||
                          _loadingIndicators.isNotEmpty
                      ? null
                      : () => _explain(ticker),
                  icon: const Icon(Icons.auto_awesome_outlined),
                  label: Text(
                    _analyzing.contains(ticker) ? 'Analyzing...' : 'Ask AI',
                  ),
                ),
              if (_analysisErrors[ticker] case final error?)
                Text(
                  error,
                  key: Key('analysis_error_$ticker'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              if (_explanations[ticker] case final explanation?)
                ExpansionTile(
                  key: Key('analysis_$ticker'),
                  initiallyExpanded: true,
                  tilePadding: EdgeInsets.zero,
                  title: Text('${explanation.provider} / ${explanation.model}'),
                  subtitle: const Text('AI explanation - verify independently'),
                  children: [
                    SelectableText(explanation.text),
                    if (explanation.toolsUsed.isNotEmpty)
                      Text('Tools used: ${explanation.toolsUsed.join(', ')}'),
                    for (final limitation in explanation.limitations)
                      Text(limitation),
                    for (final source in explanation.sources)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(source.title),
                            Text(
                              'Source date: ${source.publishedAt ?? 'Unavailable'}',
                            ),
                            Text(
                              'Retrieved (UTC): ${source.retrievedAt.toIso8601String()}',
                            ),
                            SelectableText(source.url.toString()),
                          ],
                        ),
                      ),
                  ],
                ),
            ] else
              Text(
                error ?? 'Waiting for provider quote...',
                key: Key('quote_status_$ticker'),
                style: error == null
                    ? null
                    : TextStyle(color: theme.colorScheme.error),
              ),
          ],
        ),
      ),
    );
  }

  Widget _indicatorDetails(
    String ticker,
    IndicatorSnapshot snapshot,
  ) => ExpansionTile(
    key: Key('indicator_result_$ticker'),
    initiallyExpanded: true,
    tilePadding: EdgeInsets.zero,
    title: const Text('Deterministic daily indicators'),
    subtitle: Text(
      snapshot.lastSession == null
          ? 'Data unavailable'
          : 'Through ${snapshot.lastSession} - ${snapshot.lookback} sessions',
    ),
    children: [
      const Text(
        'Calculated in Dart, not by AI. Informational only; not a trade signal.',
      ),
      if (snapshot.provider != null) ...[
        Text('${snapshot.provider!.name} / ${snapshot.feed!.name} - raw bars'),
        Text(
          'Coverage: ${snapshot.coverage!.name}; volume: ${snapshot.volumeScope}',
        ),
        Text('Formula: ${snapshot.version}'),
        const Text(
          'SMA / EMA: 20 sessions; SMA trend lag: 1 session; RSI: 14 deltas.',
        ),
        Text('Analysis cutoff (UTC): ${snapshot.cutoff!.toIso8601String()}'),
      ],
      for (final entry in snapshot.metrics.entries)
        Text(
          '${_indicatorLabel(entry.key)}: ${_metricText(entry.key, entry.value)}',
        ),
      for (final limitation in snapshot.limitations.toSet()) Text(limitation),
      for (final source in snapshot.sources) ...[
        Text(
          'Source session: ${source.date}; retrieved (UTC): ${source.retrievedAt.toIso8601String()}',
        ),
        SelectableText(source.url.toString()),
      ],
    ],
  );
}

String _price(double? value) =>
    value == null ? 'Unavailable' : '\$${value.toStringAsFixed(4)}';

String _indicatorLabel(String key) => switch (key) {
  'sessionColors' => 'Green / red / flat',
  'greenToRedRatio' => 'Green:red ratio',
  'closeReturn' => 'Lookback return',
  'simpleMovingAverage' => 'SMA',
  'relativeVolume' => 'Relative volume (same feed)',
  'smaTrend' => 'SMA trend',
  'exponentialMovingAverage' => 'EMA',
  'relativeStrengthIndex' => 'RSI',
  _ => key,
};

String _metricText(String key, IndicatorMetricSnapshot metric) {
  if (!metric.isAvailable) {
    return 'Unavailable - ${_reasonLabel(metric.reason!)} '
        '(${metric.observedSamples}/${metric.requiredSamples} samples)';
  }
  if (metric.value case final SessionColorSummary colors) {
    return '${colors.greenCount} / ${colors.redCount} / ${colors.flatCount} '
        '(green ${(colors.greenFraction * 100).toStringAsFixed(1)}%)';
  }
  if (key == 'smaTrend') {
    final trend = metric.value! as Map<String, Object>;
    return '${trend['direction']} (${((trend['slope']! as double) * 100).toStringAsFixed(2)}%)';
  }
  final value = metric.value! as double;
  return key == 'closeReturn'
      ? '${(value * 100).toStringAsFixed(2)}%'
      : '${value.toStringAsFixed(4)}${metric.units == 'ratio' ? 'x' : ''}';
}

String _reasonLabel(DailyIndicatorUnavailableReason reason) => switch (reason) {
  DailyIndicatorUnavailableReason.insufficientData => 'insufficient sessions',
  DailyIndicatorUnavailableReason.coverageUnverified =>
    'session coverage unverified',
  DailyIndicatorUnavailableReason.incompleteCoverage =>
    'missing expected sessions',
  DailyIndicatorUnavailableReason.staleData => 'stale retrieved inputs',
  DailyIndicatorUnavailableReason.zeroDenominator => 'zero denominator',
  DailyIndicatorUnavailableReason.unsupportedVolumeScope =>
    'unsupported volume scope',
  DailyIndicatorUnavailableReason.nonComparableRawPrices =>
    'raw-price corporate actions unverified',
  DailyIndicatorUnavailableReason.numericalOverflow =>
    'numerical range exceeded',
};
