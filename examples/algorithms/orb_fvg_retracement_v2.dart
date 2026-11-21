// v2: preserves the original trading filters; supplies explicit short/cover
// direction and the planned protective target through the current simulator API.
// Import this as a new algorithm. Existing saved strategy versions stay pinned.
// Brendon Trade Helper - 15-minute New York ORB / FVG / zone retracement.
// Import via Simulation controls > Add algorithm from file.
// Source: Nov 19 video (opening range, breakout, FVG or preferred demand
// zone, retracement, then target the original breakout). The bearish mirror,
// closed-bar rejection, zone definitions, stops, R:R and cutoffs are design
// choices, not exact rules stated in the video.
//
// SDK assumptions: sessionElapsedMinutes is measured from 09:30 New York
// regular-session open to the END of the latest completed candle. Candles
// must be contiguous, aligned to that open, and retained from session start.
// Context supplies candle-close timestamps and position metadata. This
// implementation assumes contiguous history from the session open. Configure
// regular U.S. equity hours and 1-, 3- or 5-minute bars.
// Short mode is opt-in and also requires the simulator short-selling switch.
// Signals use explicit short/open and short/close sides. No order submission.
// One entry opportunity per session; history is replayed deterministically.
// Target/stop-close fallback signals use completed closes, not exact fills.
// The stop field is passed to the host for its protective stop handling.

import 'dart:math' as math;
import 'package:atrader/strategy_api.dart';

class OrbFvgRetracementStrategy implements TradingStrategy {
  const OrbFvgRetracementStrategy();

  @override
  String get id => 'orb_fvg_retracement_v2';
  @override
  String get name => '15-min ORB + FVG / Demand-Supply Retracement v2';
  @override
  String get description =>
      'Break the first 15-minute regular-session range, wait for a return '
      'to a fair value gap or preferred demand/supply zone and a later '
      'rejection candle. Target the prior breakout extreme. One setup entry '
      'per session; long by default, optional bearish mirror.';

  @override
  int get warmupBars => 3;

  @override
  List<StrategyParameter> get parameters => const [
    StrategyParameter(
      name: 'enableShort',
      label: 'Enable bearish mirror (0/1)',
      unit: 'flag',
      defaultValue: 0,
      minimum: 0,
      maximum: 1,
    ),
    StrategyParameter(
      name: 'zoneMode',
      label: 'Zone: 0 either, 1 FVG only, 2 demand/supply only',
      unit: 'mode',
      defaultValue: 0,
      minimum: 0,
      maximum: 2,
    ),
    StrategyParameter(
      name: 'minGapFraction',
      label: 'Minimum FVG size / price',
      unit: 'fraction',
      defaultValue: 0.001,
      minimum: 0,
      maximum: 0.05,
    ),
    StrategyParameter(
      name: 'displacementMultiple',
      label: 'Impulse body / base range',
      unit: 'x',
      defaultValue: 1.5,
      minimum: 0.5,
      maximum: 4,
    ),
    StrategyParameter(
      name: 'stopBufferFraction',
      label: 'Buffer beyond zone / price',
      unit: 'fraction',
      defaultValue: 0.002,
      minimum: 0,
      maximum: 0.03,
    ),
    StrategyParameter(
      name: 'minRewardRisk',
      label: 'Minimum planned reward/risk',
      unit: 'x',
      defaultValue: 2,
      minimum: 0,
      maximum: 5,
    ),
    StrategyParameter(
      name: 'setupExpiryMinutes',
      label: 'Max minutes from breakout to entry',
      unit: 'minutes',
      defaultValue: 60,
      minimum: 10,
      maximum: 180,
    ),
    StrategyParameter(
      name: 'lastEntryMinute',
      label: 'Last entry minutes after market open',
      unit: 'minutes',
      defaultValue: 120,
      minimum: 30,
      maximum: 300,
    ),
    StrategyParameter(
      name: 'exitMinute',
      label: 'Time exit minutes after market open',
      unit: 'minutes',
      defaultValue: 385,
      minimum: 60,
      maximum: 390,
    ),
  ];

  double _parameter(StrategyContext context, String name) {
    final p = parameters.firstWhere((item) => item.name == name);
    final value = context.parameter(name, p.defaultValue);
    return value.isFinite
        ? value.clamp(p.minimum, p.maximum).toDouble()
        : p.defaultValue;
  }

  @override
  StrategySignal evaluate(StrategyContext context) {
    const openingMinutes = 15;
    final elapsed = context.sessionElapsedMinutes;
    final interval = context.intervalMinutes;
    final exitMinute = _parameter(context, 'exitMinute').round();
    final lastEntry = math.min(
      _parameter(context, 'lastEntryMinute').round(),
      exitMinute - 1,
    );
    final shorts = _parameter(context, 'enableShort') >= 0.5;
    final isLong = context.positionSide == PositionSide.long;
    final isShort = context.positionSide == PositionSide.short;

    if (context.hasPosition && !isLong && !isShort) {
      return const StrategySignal(TradeAction.wait, 'Unknown position side.');
    }
    // This is a time-exit signal, not a guaranteed same-bar liquidation.
    if (context.hasPosition && elapsed != null && elapsed >= exitMinute) {
      return _close(isLong, 'Regular-session time exit.');
    }
    if (interval != 1 && interval != 3 && interval != 5) {
      return const StrategySignal(
        TradeAction.wait,
        'Use 1-, 3- or 5-minute candles.',
      );
    }
    if (elapsed == null || elapsed < 0 || elapsed > 390) {
      return const StrategySignal(
        TradeAction.wait,
        'No valid regular-session clock.',
      );
    }
    if (elapsed <= openingMinutes) {
      if (context.hasPosition) {
        return _close(isLong, 'Unexpected position at new session opening.');
      }
      return const StrategySignal(
        TradeAction.wait,
        'Building the 09:30-09:45 ET range.',
      );
    }
    if (elapsed % interval != 0) {
      return const StrategySignal(
        TradeAction.wait,
        'Session clock not aligned to completed bars.',
      );
    }
    final sessionBars = (elapsed / interval).floor();
    final openingBars = (openingMinutes / interval).round();
    final all = context.candles;
    if (all.length < sessionBars || sessionBars <= openingBars) {
      return const StrategySignal(
        TradeAction.wait,
        'Need full completed session history.',
      );
    }
    final bars = all.skip(all.length - sessionBars).toList();
    // Validate only the visible history; the SDK must supply correct timestamps.
    for (final b in bars) {
      if (!b.open.isFinite ||
          !b.high.isFinite ||
          !b.low.isFinite ||
          !b.close.isFinite ||
          b.low <= 0 ||
          b.high < math.max(b.open, b.close) ||
          b.low > math.min(b.open, b.close)) {
        return const StrategySignal(TradeAction.wait, 'Invalid OHLC data.');
      }
    }
    var rangeHigh = bars.first.high.toDouble();
    var rangeLow = bars.first.low.toDouble();
    for (var i = 1; i < openingBars; i++) {
      rangeHigh = math.max(rangeHigh, bars[i].high.toDouble());
      rangeLow = math.min(rangeLow, bars[i].low.toDouble());
    }
    final baseMeasurements = <String, double>{
      'rangeHigh': rangeHigh,
      'rangeLow': rangeLow,
    };
    if (rangeHigh <= rangeLow) {
      return StrategySignal(
        TradeAction.wait,
        'Opening range has no width.',
        measurements: baseMeasurements,
      );
    }

    final mode = _parameter(context, 'zoneMode').round();
    final minGap = _parameter(context, 'minGapFraction');
    final impulse = _parameter(context, 'displacementMultiple');
    final buffer = _parameter(context, 'stopBufferFraction');
    final minRR = _parameter(context, 'minRewardRisk');
    final expiry = _parameter(context, 'setupExpiryMinutes').round();
    final zones = <_OrbZone>[];
    var direction = 0; // +1 bullish, -1 bearish.
    var breakIndex = -1;
    var extreme = 0.0;
    _OrbPlan? plan;

    // Replay only completed candles in chronological order. No mutable global
    // state and no use of bars after a historical entry decision.
    for (var i = openingBars; i < bars.length; i++) {
      final b = bars[i];
      final barMinute = (i + 1) * interval;
      if (barMinute > lastEntry) break;
      final close = b.close.toDouble();
      final low = b.low.toDouble();
      final high = b.high.toDouble();
      final open = b.open.toDouble();

      // First close outside the opening range sets today's setup direction.
      // An opposite breakout or expiry invalidates it; no re-entry that day.
      if (direction == 0) {
        if (close > rangeHigh) {
          direction = 1;
        } else if (close < rangeLow && shorts) {
          direction = -1;
        } else {
          continue;
        }
        breakIndex = i;
        extreme = direction == 1 ? high : low;
      }
      final bullish = direction == 1;
      if ((i - breakIndex) * interval > expiry ||
          (bullish && close < rangeLow) ||
          (!bullish && close > rangeHigh)) {
        break;
      }

      // A zone can only be touched on a later candle, never its creation bar.
      // Freeze the target at the prior breakout extreme on first touch;
      // subsequent candles cannot move that target further away.
      _OrbPlan? candidate;
      var candidateKind = -1;
      for (final z in zones) {
        if (z.invalid || i <= z.createdAt) continue;
        if ((bullish && close < z.bottom) || (!bullish && close > z.top)) {
          z.invalid = true;
          continue;
        }
        if (z.touchedAt < 0 && low <= z.top && high >= z.bottom) {
          z.touchedAt = i;
          z.target = extreme;
          z.pullbackExtreme = bullish ? low : high;
        } else if (z.touchedAt >= 0) {
          z.pullbackExtreme = bullish
              ? math.min(z.pullbackExtreme, low)
              : math.max(z.pullbackExtreme, high);
        }
        if (z.touchedAt < 0) continue;
        // If the target was reached before an entry, the setup has played out.
        // Ignore the touch bar for this check: intrabar ordering is unknown.
        if (i > z.touchedAt && (bullish ? high >= z.target : low <= z.target)) {
          z.invalid = true;
          continue;
        }
        if (i <= z.touchedAt) continue;
        final rejects = bullish
            ? close > open && close > z.top && close > rangeHigh
            : close < open && close < z.bottom && close < rangeLow;
        if (!rejects) continue;
        final stop = bullish
            ? math.min(z.bottom, z.pullbackExtreme) - close * buffer
            : math.max(z.top, z.pullbackExtreme) + close * buffer;
        final risk = bullish ? close - stop : stop - close;
        final reward = bullish ? z.target - close : close - z.target;
        if (stop <= 0 || risk <= 0 || reward <= 0 || reward / risk < minRR) {
          continue;
        }
        // Prefer a valid demand/supply candidate over an FVG on the same bar.
        // Among equally ranked zones, prefer the more recently formed one.
        if (z.kind >= candidateKind) {
          candidateKind = z.kind;
          candidate = _OrbPlan(
            direction,
            i,
            close,
            stop,
            z.target,
            z.bottom,
            z.top,
            reward / risk,
            z.kind,
          );
        }
      }
      if (candidate != null) {
        plan = candidate;
        break;
      }

      // FVG: non-overlapping first/third candle wicks in breakout direction.
      // Require a directional middle candle, and its formation at or after
      // the breakout. A first candle from the opening range is permitted.
      if (mode != 2 && i >= 2 && i > breakIndex) {
        final a = bars[i - 2];
        final m = bars[i - 1];
        final gapBottom = bullish ? a.high.toDouble() : high;
        final gapTop = bullish ? low : a.low.toDouble();
        final directional = bullish ? m.close > m.open : m.close < m.open;
        if (directional &&
            gapTop > gapBottom &&
            (gapTop - gapBottom) / close >= minGap) {
          zones.add(_OrbZone(gapBottom, gapTop, i, 0));
        }
      }

      // Objective demand/supply proxy: last opposite-color base candle,
      // followed by a directional displacement candle closing beyond it.
      // Use the base's full wick-to-wick range as the zone.
      if (mode != 1 && i >= 1) {
        final base = bars[i - 1];
        final baseRange = base.high.toDouble() - base.low.toDouble();
        final directionalBase = bullish
            ? base.close < base.open
            : base.close > base.open;
        final directionalImpulse = bullish
            ? close > open && close > base.high
            : close < open && close < base.low;
        if (baseRange > 0 &&
            directionalBase &&
            directionalImpulse &&
            (close - open).abs() >= impulse * baseRange) {
          zones.add(_OrbZone(base.low.toDouble(), base.high.toDouble(), i, 1));
        }
      }
      extreme = bullish ? math.max(extreme, high) : math.min(extreme, low);
    }

    if (plan == null) {
      if (context.hasPosition) {
        return _close(
          isLong,
          'Cannot reconstruct the entry plan; defensive exit.',
        );
      }
      return StrategySignal(
        TradeAction.wait,
        'Waiting for breakout, eligible zone, retracement and rejection.',
        measurements: baseMeasurements,
      );
    }
    final measurements = <String, double>{
      ...baseMeasurements,
      'breakoutDirection': plan.direction.toDouble(),
      'zoneType': plan.kind.toDouble(), // 0 FVG, 1 demand/supply
      'zoneLow': plan.bottom, 'zoneHigh': plan.top,
      'signalEntry': plan.entry, 'stopPrice': plan.stop,
      'targetPrice': plan.target, 'plannedRewardRisk': plan.rewardRisk,
    };
    final longPlan = plan.direction == 1;
    final current = bars.last.close.toDouble();
    final latestIndex = bars.length - 1;

    if (context.hasPosition) {
      if (isLong != longPlan) {
        return _close(
          isLong,
          'Position side differs from reconstructed setup.',
          measurements,
        );
      }
      if (longPlan ? current >= plan.target : current <= plan.target) {
        return _close(
          isLong,
          'Close reached original breakout extreme.',
          measurements,
        );
      }
      if (longPlan ? current <= plan.stop : current >= plan.stop) {
        return _close(
          isLong,
          'Close crossed protective stop level.',
          measurements,
        );
      }
      return StrategySignal(
        TradeAction.wait,
        'Holding toward original breakout extreme.',
        measurements: measurements,
      );
    }
    if (latestIndex != plan.index || elapsed >= exitMinute) {
      return StrategySignal(
        TradeAction.wait,
        'Entry opportunity already passed; no chase or re-entry.',
        measurements: measurements,
      );
    }
    return StrategySignal(
      longPlan ? TradeAction.buy : TradeAction.sell,
      longPlan
          ? 'Bullish ORB zone retracement and rejection.'
          : 'Bearish ORB zone retracement and rejection.',
      side: longPlan ? PositionSide.long : PositionSide.short,
      positionEffect: PositionEffect.open,
      stop: plan.stop,
      target: plan.target,
      measurements: measurements,
    );
  }

  StrategySignal _close(
    bool longPosition,
    String reason, [
    Map<String, double>? measurements,
  ]) {
    return StrategySignal(
      longPosition ? TradeAction.sell : TradeAction.buy,
      reason,
      side: longPosition ? PositionSide.long : PositionSide.short,
      positionEffect: PositionEffect.close,
      measurements: measurements ?? const <String, double>{},
    );
  }
}

// Local replay state only; no global/static mutable variables.
class _OrbZone {
  _OrbZone(this.bottom, this.top, this.createdAt, this.kind);
  final double bottom, top;
  final int createdAt, kind;
  bool invalid = false;
  int touchedAt = -1;
  double target = 0, pullbackExtreme = 0;
}

class _OrbPlan {
  const _OrbPlan(
    this.direction,
    this.index,
    this.entry,
    this.stop,
    this.target,
    this.bottom,
    this.top,
    this.rewardRisk,
    this.kind,
  );
  final int direction, index, kind;
  final double entry, stop, target, bottom, top, rewardRisk;
}
