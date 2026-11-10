import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'local_market_data_service.dart';
import 'market_data.dart';

class DailyCandlePresentation extends StatelessWidget {
  const DailyCandlePresentation({
    required this.symbol,
    this.snapshot,
    this.error,
    this.loading = false,
    super.key,
  });

  final String symbol;
  final BarSnapshot? snapshot;
  final String? error;
  final bool loading;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      const SizedBox(height: 16),
      Text(
        '$symbol daily candles',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const Text(
        'Historical OHLCV only - not a prediction. Last 30 calendar days, '
        'ending at today\'s UTC midnight; no intraday or live updates. '
        'Missing dates are not filled. The latest session may be absent.',
      ),
      const SizedBox(height: 12),
      if (loading) ...[
        const LinearProgressIndicator(),
        const Text('Loading daily candles (provider pacing may apply)...'),
      ] else if (error != null)
        Text(
          error!,
          key: const Key('daily_chart_error'),
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        )
      else if (snapshot case final snapshot?) ...[
        Text('${snapshot.provider.name} / ${snapshot.feed.name}'),
        Text(marketCoverage(snapshot.provider)),
        if (snapshot.bars.isEmpty)
          const Text(
            'No daily candles returned for this window.',
            key: Key('daily_chart_empty'),
          )
        else
          DailyCandleChart(key: ValueKey(snapshot), bars: snapshot.bars),
      ] else
        const Text('Daily candles queued: waiting for earlier cards.'),
    ],
  );
}

class DailyCandleChart extends StatefulWidget {
  const DailyCandleChart({required this.bars, super.key});

  final List<MarketBar> bars;

  @override
  State<DailyCandleChart> createState() => _DailyCandleChartState();
}

class _DailyCandleChartState extends State<DailyCandleChart> {
  late int _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.bars.length - 1;
  }

  @override
  void didUpdateWidget(DailyCandleChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bars != widget.bars) _selected = widget.bars.length - 1;
  }

  void _select(int index) {
    if (index != _selected) setState(() => _selected = index);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.bars.isEmpty) return const Text('No daily candles.');
    final bar = widget.bars[_selected];
    final theme = Theme.of(context);
    final date = _date(bar);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Text(
          '${widget.bars.length} returned daily candles; equal spacing represents '
          'returned observations, not continuous calendar time.',
        ),
        const Text(
          'Green: close > open. Red: close < open. Gray: unchanged. '
          'Wicks: low/high. Lower bars: same-feed volume.',
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            final width = math.max(
              constraints.maxWidth,
              widget.bars.length * 22.0 + 72,
            );
            int indexAt(double x) =>
                ((x - 64) / (width - 72) * widget.bars.length).floor().clamp(
                  0,
                  widget.bars.length - 1,
                );
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: MouseRegion(
                onHover: (event) => _select(indexAt(event.localPosition.dx)),
                child: GestureDetector(
                  onTapDown: (event) =>
                      _select(indexAt(event.localPosition.dx)),
                  child: Semantics(
                    label:
                        'Historical daily price and volume chart. '
                        'Use the candle selector below for exact values.',
                    image: true,
                    child: CustomPaint(
                      key: const Key('daily_candle_plot'),
                      size: Size(width, 290),
                      painter: DailyCandlePainter(
                        bars: widget.bars,
                        selected: _selected,
                        foreground: theme.colorScheme.onSurface,
                        grid: theme.colorScheme.outlineVariant,
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        if (widget.bars.length > 1)
          Slider(
            key: const Key('daily_candle_selector'),
            value: _selected.toDouble(),
            min: 0,
            max: widget.bars.length - 1.0,
            divisions: widget.bars.length - 1,
            label: date,
            semanticFormatterCallback: (value) =>
                _date(widget.bars[value.round()]),
            onChanged: (value) => _select(value.round()),
          ),
        Semantics(
          liveRegion: true,
          child: Text(
            '$date | O ${_price(bar.open)}  H ${_price(bar.high)}  '
            'L ${_price(bar.low)}  C ${_price(bar.close)} | '
            'Volume ${bar.volume} shares',
            key: const Key('daily_candle_values'),
          ),
        ),
        Text(
          'Date basis: ${bar.tradingDate == null ? 'UTC date proxy (not verified exchange session)' : bar.timestampSemantics ?? 'exchangeTradingDate'}'
          '${bar.exchangeTimezone == null ? '; exchange timezone unknown' : '; ${bar.exchangeTimezone}'}. '
          'Adjustment: ${bar.adjustment.name}. '
          'Corporate actions may distort comparisons; no returns are calculated.',
        ),
        Text(
          'Source timestamp (UTC): ${bar.timestamp.toUtc().toIso8601String()}\n'
          'Retrieved (UTC): ${bar.retrievedAt.toUtc().toIso8601String()}',
        ),
        const Text(
          'Forecast overlay not implemented. No confidence or accuracy is claimed.',
        ),
      ],
    );
  }
}

String _date(MarketBar bar) =>
    bar.tradingDate ?? bar.timestamp.toUtc().toIso8601String().substring(0, 10);

String _price(double value) => value.toStringAsFixed(value < 1 ? 6 : 4);

class DailyCandlePainter extends CustomPainter {
  DailyCandlePainter({
    required this.bars,
    required this.selected,
    required this.foreground,
    required this.grid,
  });

  final List<MarketBar> bars;
  final int selected;
  final Color foreground;
  final Color grid;

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;
    const top = 14.0;
    const bottom = 194.0;
    final low = bars.map((bar) => bar.low).reduce(math.min);
    final high = bars.map((bar) => bar.high).reduce(math.max);
    final padding = math.max((high - low) * 0.06, high * 0.005);
    final minimum = low - padding;
    final maximum = high + padding;
    double y(double value) =>
        top + (maximum - value) / (maximum - minimum) * (bottom - top);
    final step = (size.width - 72) / bars.length;
    double x(int index) => 64 + (index + 0.5) * step;
    final maxVolume = bars.map((bar) => bar.volume).reduce(math.max);
    void label(String text, Offset position) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(color: foreground, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(canvas, position);
    }

    for (var tick = 0; tick < 4; tick++) {
      final price = minimum + (maximum - minimum) * tick / 3;
      final position = y(price);
      canvas.drawLine(
        Offset(62, position),
        Offset(size.width - 8, position),
        Paint()..color = grid,
      );
      label(_price(price), Offset(0, position - 6));
    }
    canvas.drawLine(
      Offset(x(selected), top),
      Offset(x(selected), 256),
      Paint()
        ..color = foreground.withValues(alpha: 0.35)
        ..strokeWidth = 1,
    );
    for (var index = 0; index < bars.length; index++) {
      final bar = bars[index];
      final color = bar.close > bar.open
          ? const Color(0xFF21894B)
          : bar.close < bar.open
          ? const Color(0xFFD54A50)
          : const Color(0xFF888888);
      final paint = Paint()
        ..color = color
        ..strokeWidth = 1.5;
      canvas.drawLine(
        Offset(x(index), y(bar.high)),
        Offset(x(index), y(bar.low)),
        paint,
      );
      canvas.drawRect(
        Rect.fromCenter(
          center: Offset(x(index), (y(bar.open) + y(bar.close)) / 2),
          width: math.min(step * 0.65, 16),
          height: math.max((y(bar.open) - y(bar.close)).abs(), 1.5),
        ),
        paint,
      );
      if (maxVolume > 0 && bar.volume > 0) {
        canvas.drawRect(
          Rect.fromLTWH(
            x(index) - math.min(step * 0.65, 16) / 2,
            256 - 42 * bar.volume / maxVolume,
            math.min(step * 0.65, 16),
            42 * bar.volume / maxVolume,
          ),
          paint..color = color.withValues(alpha: 0.65),
        );
      }
    }
    label('Volume', const Offset(0, 216));
    label(_date(bars.first), const Offset(64, 270));
    if (size.width > 240 && bars.length > 1) {
      label(_date(bars.last), Offset(size.width - 72, 270));
    }
  }

  @override
  bool shouldRepaint(DailyCandlePainter oldDelegate) =>
      bars != oldDelegate.bars ||
      selected != oldDelegate.selected ||
      foreground != oldDelegate.foreground ||
      grid != oldDelegate.grid;
}
