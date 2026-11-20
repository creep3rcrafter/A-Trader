/// Historical replay that cannot look ahead.
///
/// Schwab one-minute bars are turned into a strictly time-ordered stream of
/// point-in-time quotes. The quotes go through the same
/// [LiveSimulationRuntime] path as live data, with a simulated clock set to
/// each quote's timestamp. Strategies and the engine never see the downloaded
/// bar list. They only see quotes that have already "happened", so:
///
/// * a decision candle completes only when the first quote of the next bucket
///   arrives, and it contains only earlier minutes;
/// * an order queued by that decision fills at a later quote (the next
///   minute's open), never at a price from the decision candle;
/// * stops and targets trigger on quotes in time order.
///
/// Within one minute the true trade path is unknown, so each bar is replayed
/// as open, then the extreme nearer the open (low for up bars, high for down
/// bars), then the other extreme, then the close. Synthetic quotes set
/// bid = ask = price; the configured half-spread and slippage are applied at
/// fill time exactly as in live mode.
library;

import 'dart:async';

import 'exchange_calendar.dart';
import 'live_runtime.dart';
import 'mountain_time.dart';
import 'simulator.dart';

typedef HistoricalRange = ({DateTime startUtc, DateTime endUtc, String label});

/// One Schwab price-history bar. [openTime] is the start of the minute.
class MinuteBar {
  const MinuteBar({
    required this.symbol,
    required this.openTime,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
  });

  final String symbol;
  final DateTime openTime;
  final double open;
  final double high;
  final double low;
  final double close;
  final double volume;
}

/// Converts one-minute bars into quotes ordered by event time.
///
/// Only regular-session bars are kept. Cumulative session volume rises only
/// at each minute's closing quote, so a minute's volume can't appear before
/// the minute ends.
List<LiveQuote> quotesFromMinuteBars(
  Map<String, List<MinuteBar>> barsBySymbol,
) {
  final quotes = <LiveQuote>[];
  for (final entry in barsBySymbol.entries) {
    final bars = [...entry.value]
      ..sort((a, b) => a.openTime.compareTo(b.openTime));
    var cumulativeVolume = 0.0;
    DateTime? currentSessionDate;
    for (final bar in bars) {
      final session = UsEquityCalendar.sessionAt(bar.openTime);
      if (session == null) continue;
      if (session.date != currentSessionDate) {
        currentSessionDate = session.date;
        cumulativeVolume = 0;
      }
      LiveQuote quote(int offsetMs, double price, double volume) => LiveQuote(
        symbol: entry.key,
        time: bar.openTime.add(Duration(milliseconds: offsetMs)),
        bid: price,
        ask: price,
        last: price,
        volume: volume,
        realTime: true,
      );
      final upBar = bar.close >= bar.open;
      final firstExtreme = upBar ? bar.low : bar.high;
      final secondExtreme = upBar ? bar.high : bar.low;
      // The open is emitted twice: the first event completes the previous
      // decision candle, and the 1 ms later event is the first price an order
      // from that decision is allowed to fill at.
      quotes
        ..add(quote(0, bar.open, cumulativeVolume))
        ..add(quote(1, bar.open, cumulativeVolume))
        ..add(quote(20000, firstExtreme, cumulativeVolume))
        ..add(quote(40000, secondExtreme, cumulativeVolume));
      cumulativeVolume += bar.volume;
      quotes.add(quote(59999, bar.close, cumulativeVolume));
    }
  }
  quotes.sort((a, b) {
    final byTime = a.time.compareTo(b.time);
    return byTime != 0 ? byTime : a.symbol.compareTo(b.symbol);
  });
  return quotes;
}

/// Mutable simulated clock shared by a replay and its runtime.
class ReplayClock {
  DateTime now = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  DateTime call() => now;
}

/// Feeds historical quotes through a runtime as fast as the event loop
/// allows, awaiting decision hooks and yielding so requests remain responsive.
class HistoricalReplay {
  HistoricalReplay({
    required this.runtime,
    required this.clock,
    required this.quotes,
    required this.rangeLabel,
    this.quotesPerSlice = 4000,
    this.beforeDecision,
  });

  final LiveSimulationRuntime runtime;
  final ReplayClock clock;
  final List<LiveQuote> quotes;
  final String rangeLabel;
  final int quotesPerSlice;
  final Future<void> Function(int interval, SimulatorEngine engine, Candle bar)?
  beforeDecision;
  int processed = 0;
  bool finished = false;

  double get progress => quotes.isEmpty ? 1 : processed / quotes.length;

  /// Runs until every quote is processed or [LiveSimulationRuntime.running]
  /// is set false by Stop.
  Future<void> run() async {
    runtime
      ..setConnected(true)
      ..begin();
    while (processed < quotes.length) {
      if (!runtime.running) {
        runtime.runStatus =
            'Historical replay stopped at ${_day(clock.now)} ($rangeLabel)';
        finished = true;
        return;
      }
      final end = (processed + quotesPerSlice).clamp(0, quotes.length);
      for (; processed < end; processed++) {
        final quote = quotes[processed];
        clock.now = quote.time;
        final prepare = beforeDecision;
        if (prepare == null) {
          runtime.onQuote(quote);
        } else {
          await runtime.onQuoteAwaitingDecisions(
            quote,
            beforeDecision: prepare,
          );
        }
        if (!runtime.running) break;
      }
      runtime.runStatus =
          'Historical replay ${(progress * 100).toStringAsFixed(0)}% — '
          'simulated time ${_day(clock.now)} ($rangeLabel)';
      await Future<void>.delayed(Duration.zero);
    }
    runtime
      ..running = false
      ..runStatus = 'Historical replay complete ($rangeLabel)';
    finished = true;
  }

  static String _day(DateTime time) =>
      MountainTime.format(time, includeSeconds: false);
}
