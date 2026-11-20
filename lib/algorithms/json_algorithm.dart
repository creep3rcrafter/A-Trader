import 'dart:math' as math;

import '../strategy_api.dart';
import 'imported_definition.dart';

/// Deterministic expression-based strategy. Expressions are parsed at import.
class JsonAlgorithm extends ImportedAlgorithmDefinition {
  JsonAlgorithm(Map<String, dynamic> json) : super.fromJson(json) {
    if (!const {
          'atrader.algorithm',
          'atrader.algorithm.draft',
        }.contains(json['format']) ||
        json['version'] != 1) {
      throw const FormatException(
        'Use format atrader.algorithm and version 1.',
      );
    }
    if (json['kind'] != 'rules') {
      throw const FormatException(
        'JSON imports currently support kind "rules". For model selection, use the existing LM Studio strategy.',
      );
    }
    if (json['intervalMinutes'] != null && json['intervalMinutes'] != 1) {
      throw const FormatException(
        'Imported JSON algorithms use 1-minute candles.',
      );
    }
    final names = {..._contextNames, 'true', 'false', 'null'};
    for (final parameter in parameters) {
      if (!names.add(parameter.name) || _functions.contains(parameter.name)) {
        throw FormatException(
          'Parameter ${parameter.name} conflicts with a reserved name.',
        );
      }
      if (((json['parameters'] as Map)[parameter.name] as Map)['round'] ==
          true) {
        _rounded.add(parameter.name);
      }
    }
    final calculations = json['calculations'] ?? <String, dynamic>{};
    if (calculations is! Map || calculations.length > 64) {
      throw const FormatException(
        'calculations must be an object with at most 64 entries.',
      );
    }
    for (final entry in calculations.entries) {
      final key = entry.key;
      if (key is! String ||
          !RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]{0,79}$').hasMatch(key) ||
          names.contains(key) ||
          _functions.contains(key)) {
        throw FormatException('Invalid or duplicate calculation name: $key.');
      }
      _calculations[key] = _parse(entry.value, names);
      names.add(key);
    }
    final rules = json['rules'];
    if (rules is! List || rules.isEmpty || rules.length > 128) {
      throw const FormatException('Provide 1 to 128 rules.');
    }
    for (final raw in rules) {
      if (raw is! Map) {
        throw const FormatException('Each rule must be an object.');
      }
      final action = TradeAction.values
          .where((a) => a.name == raw['action'])
          .firstOrNull;
      final side = PositionSide.values
          .where((s) => s.name == (raw['side'] ?? 'long'))
          .firstOrNull;
      final effect = PositionEffect.values
          .where((e) => e.name == raw['positionEffect'])
          .firstOrNull;
      if (action == null ||
          side == null ||
          (action != TradeAction.wait && effect == null)) {
        throw const FormatException(
          'Rules need action buy/sell/wait, side long/short, and positionEffect open/close for trade signals.',
        );
      }
      if (effect == PositionEffect.open &&
              action !=
                  (side == PositionSide.long
                      ? TradeAction.buy
                      : TradeAction.sell) ||
          effect == PositionEffect.close &&
              action !=
                  (side == PositionSide.long
                      ? TradeAction.sell
                      : TradeAction.buy)) {
        throw const FormatException(
          'Rule action must match its position side and open/close effect.',
        );
      }
      _rules.add(
        _Rule(
          _parse(raw['when'], names),
          action,
          side,
          effect,
          raw['reason']?.toString() ?? 'Imported rule matched.',
          raw['stop'] == null ? null : _parse(raw['stop'], names),
          raw['target'] == null ? null : _parse(raw['target'], names),
        ),
      );
    }
    final fallback = json['fallback'];
    if (fallback != null &&
        (fallback is! Map || fallback['action'] != 'wait')) {
      throw const FormatException('fallback must use action wait.');
    }
    _fallback =
        (fallback as Map?)?['reason']?.toString() ??
        'No entry or exit condition matched.';
  }

  final _rounded = <String>{};
  final _calculations = <String, _Expression>{};
  final _rules = <_Rule>[];
  late final String _fallback;

  @override
  StrategySignal evaluate(StrategyContext context) {
    try {
      if (context.candles.length < warmupBars) {
        return const StrategySignal(
          TradeAction.wait,
          'Waiting for completed candles.',
        );
      }
      final variables = <String, Object?>{
        'hasPosition': context.hasPosition,
        'positionSide': context.positionSide.name,
        'entryPrice': context.entryPrice,
        'positionStop': context.positionStop,
        'barsHeld': context.barsHeld,
        'intervalMinutes': context.intervalMinutes,
        'sessionElapsedMinutes': context.sessionElapsedMinutes,
        'sessionLengthMinutes': context.sessionLengthMinutes,
      };
      for (final p in parameters) {
        final supplied = context.parameters[p.name] ?? p.defaultValue;
        final value = (supplied.isFinite ? supplied : p.defaultValue)
            .clamp(p.minimum, p.maximum)
            .toDouble();
        variables[p.name] = _rounded.contains(p.name)
            ? value.roundToDouble()
            : value;
      }
      final evaluation = _Evaluation(context, variables);
      final measurements = <String, double>{};
      for (final entry in _calculations.entries) {
        final value = entry.value.evaluate(evaluation);
        variables[entry.key] = value;
        if (value is num) measurements[entry.key] = _number(value);
      }
      for (final rule in _rules) {
        if (!_boolean(rule.when.evaluate(evaluation))) continue;
        if (rule.effect == PositionEffect.open && context.hasPosition ||
            rule.effect == PositionEffect.close &&
                (!context.hasPosition || rule.side != context.positionSide)) {
          continue;
        }
        double? price(_Expression? expression) {
          if (expression == null) return null;
          final result = _number(expression.evaluate(evaluation));
          if (result <= 0) {
            throw const FormatException('Stop/target must be positive.');
          }
          return result;
        }

        return StrategySignal(
          rule.action,
          rule.reason,
          side: rule.side,
          positionEffect: rule.effect,
          stop: price(rule.stop),
          target: price(rule.target),
          measurements: measurements,
        );
      }
      return StrategySignal(
        TradeAction.wait,
        _fallback,
        measurements: measurements,
      );
    } on Object catch (error) {
      return StrategySignal(TradeAction.wait, 'Algorithm $id: $error');
    }
  }
}

const _series = {'open', 'high', 'low', 'close', 'volume'};
const _contextNames = {
  ..._series,
  'hasPosition',
  'positionSide',
  'entryPrice',
  'positionStop',
  'barsHeld',
  'intervalMinutes',
  'sessionElapsedMinutes',
  'sessionLengthMinutes',
};
const _indicators = {'sma', 'ema', 'sum', 'std', 'lowest', 'highest'};
const _functions = {
  ..._indicators,
  'atr',
  'rsi',
  'abs',
  'min',
  'max',
  'round',
  'floor',
  'ceil',
  'sqrt',
  'pow',
  'clamp',
};

double _number(Object? value) {
  if (value is! num || !value.isFinite) {
    throw const FormatException(
      'Expected a finite number (check history and divisors).',
    );
  }
  return value.toDouble();
}

bool _boolean(Object? value) {
  if (value is! bool) {
    throw const FormatException('Conditions must evaluate to true or false.');
  }
  return value;
}

class _Evaluation {
  _Evaluation(this.context, this.variables);
  final StrategyContext context;
  final Map<String, Object?> variables;
  double series(String name, int offset) {
    if (offset < 0 || offset >= context.candles.length) {
      throw RangeError('Waiting for more closed candles.');
    }
    final bar = context.candles[context.candles.length - 1 - offset];
    return _number(switch (name) {
      'open' => bar.open,
      'high' => bar.high,
      'low' => bar.low,
      'close' => bar.close,
      'volume' => bar.volume,
      _ => null,
    });
  }
}

abstract class _Expression {
  Object? evaluate(_Evaluation evaluation);
}

class _Literal extends _Expression {
  _Literal(this.value);
  final Object? value;
  @override
  Object? evaluate(_Evaluation evaluation) => value;
}

class _Variable extends _Expression {
  _Variable(this.name);
  final String name;
  @override
  Object? evaluate(_Evaluation e) =>
      _series.contains(name) ? e.series(name, 0) : e.variables[name];
}

class _Index extends _Expression {
  _Index(this.name, this.offset);
  final String name;
  final _Expression offset;
  @override
  Object? evaluate(_Evaluation e) {
    final value = _number(offset.evaluate(e));
    if (value < 0 || value != value.roundToDouble()) {
      throw const FormatException(
        'Candle offsets must be nonnegative integers.',
      );
    }
    return e.series(name, value.toInt());
  }
}

class _Unary extends _Expression {
  _Unary(this.operator, this.value);
  final String operator;
  final _Expression value;
  @override
  Object? evaluate(_Evaluation e) => switch (operator) {
    '!' => !_boolean(value.evaluate(e)),
    '-' => -_number(value.evaluate(e)),
    _ => _number(value.evaluate(e)),
  };
}

class _Binary extends _Expression {
  _Binary(this.left, this.operator, this.right);
  final _Expression left, right;
  final String operator;
  @override
  Object? evaluate(_Evaluation e) {
    final a = left.evaluate(e);
    if (operator == '&&') return _boolean(a) && _boolean(right.evaluate(e));
    if (operator == '||') return _boolean(a) || _boolean(right.evaluate(e));
    final b = right.evaluate(e);
    if (operator == '==') return a == b;
    if (operator == '!=') return a != b;
    final x = _number(a), y = _number(b);
    return switch (operator) {
      '+' => _number(x + y),
      '-' => _number(x - y),
      '*' => _number(x * y),
      '/' => _number(x / y),
      '%' => _number(x % y),
      '>' => x > y,
      '<' => x < y,
      '>=' => x >= y,
      '<=' => x <= y,
      _ => throw const FormatException('Unsupported operator.'),
    };
  }
}

class _Call extends _Expression {
  _Call(this.name, this.args);
  final String name;
  final List<_Expression> args;
  @override
  Object? evaluate(_Evaluation e) {
    double arg(int i) => _number(args[i].evaluate(e));
    if (_indicators.contains(name) || name == 'rsi' || name == 'atr') {
      final periodValue = arg(name == 'atr' ? 0 : 1);
      if (periodValue < 1 ||
          periodValue > 10000 ||
          periodValue != periodValue.roundToDouble()) {
        throw const FormatException(
          'Indicator periods must be integers from 1 to 10000.',
        );
      }
      final period = periodValue.toInt();
      if (name == 'atr') {
        var total = 0.0;
        for (var i = 0; i < period; i++) {
          final high = e.series('high', i),
              low = e.series('low', i),
              previous = e.series('close', i + 1);
          total += math.max(
            high - low,
            math.max((high - previous).abs(), (low - previous).abs()),
          );
        }
        return total / period;
      }
      final series = (args.first as _Variable).name;
      if (name == 'rsi') {
        var gains = 0.0, losses = 0.0;
        for (var i = 0; i < period; i++) {
          final change = e.series(series, i) - e.series(series, i + 1);
          gains += math.max(0, change);
          losses += math.max(0, -change);
        }
        return gains == 0 && losses == 0
            ? 50.0
            : losses == 0
            ? 100.0
            : 100 - 100 / (1 + gains / losses);
      }
      final values = [
        for (var i = period - 1; i >= 0; i--) e.series(series, i),
      ];
      final total = values.fold<double>(0.0, (a, b) => a + b),
          mean = total / period;
      return _number(switch (name) {
        'sum' => total,
        'sma' => mean,
        'lowest' => values.reduce(math.min),
        'highest' => values.reduce(math.max),
        'std' => math.sqrt(
          values.fold<double>(0.0, (sum, v) => sum + (v - mean) * (v - mean)) /
              period,
        ),
        'ema' =>
          values
              .skip(1)
              .fold<double>(
                values.first,
                (previous, value) =>
                    previous + 2 / (period + 1) * (value - previous),
              ),
        _ => throw const FormatException('Unsupported indicator.'),
      });
    }
    return _number(switch (name) {
      'abs' => arg(0).abs(),
      'min' => math.min(arg(0), arg(1)),
      'max' => math.max(arg(0), arg(1)),
      'round' => arg(0).roundToDouble(),
      'floor' => arg(0).floorToDouble(),
      'ceil' => arg(0).ceilToDouble(),
      'sqrt' => math.sqrt(arg(0)),
      'pow' => math.pow(arg(0), arg(1)),
      'clamp' => arg(0).clamp(arg(1), arg(2)),
      _ => throw const FormatException('Unsupported function.'),
    });
  }
}

class _Rule {
  _Rule(
    this.when,
    this.action,
    this.side,
    this.effect,
    this.reason,
    this.stop,
    this.target,
  );
  final _Expression when;
  final TradeAction action;
  final PositionSide side;
  final PositionEffect? effect;
  final String reason;
  final _Expression? stop, target;
}

_Expression _parse(Object? value, Set<String> names) {
  if (value is num && value.isFinite) return _Literal(value.toDouble());
  if (value is bool) return _Literal(value);
  if (value is! String || value.isEmpty || value.length > 2048) {
    throw const FormatException(
      'Expressions must be nonempty strings up to 2048 characters.',
    );
  }
  return _Parser(value, names).parse();
}

class _Parser {
  _Parser(this.source, this.names) {
    final token = RegExp(
      r'''\s*(?:(\d+(?:\.\d*)?(?:[eE][+-]?\d+)?|\.\d+(?:[eE][+-]?\d+)?)|([A-Za-z_][A-Za-z0-9_]*)|("[^"\r\n]*"|'[^'\r\n]*')|(&&|\|\||==|!=|>=|<=|[+*/%<>!(),\[\]-]))''',
    );
    var offset = 0;
    while (offset < source.length) {
      if (source.substring(offset).trim().isEmpty) break;
      final match = token.matchAsPrefix(source, offset);
      if (match == null) {
        throw FormatException(
          'Invalid expression near character ${offset + 1}: $source',
        );
      }
      tokens.add(
        match.group(1) ?? match.group(2) ?? match.group(3) ?? match.group(4)!,
      );
      offset = match.end;
      if (tokens.length > 512) {
        throw const FormatException('Expression is too complex.');
      }
    }
  }
  final String source;
  final Set<String> names;
  final tokens = <String>[];
  var index = 0, depth = 0;
  static const precedence = {
    '||': 1,
    '&&': 2,
    '==': 3,
    '!=': 3,
    '>': 4,
    '<': 4,
    '>=': 4,
    '<=': 4,
    '+': 5,
    '-': 5,
    '*': 6,
    '/': 6,
    '%': 6,
  };
  String get next => index < tokens.length ? tokens[index] : '';
  bool take(String token) {
    if (next != token) return false;
    index++;
    return true;
  }

  void expect(String token) {
    if (!take(token)) {
      throw FormatException('Expected "$token" in expression: $source');
    }
  }

  _Expression parse() {
    final result = expression(0);
    if (index != tokens.length) {
      throw FormatException('Unexpected "$next" in expression: $source');
    }
    return result;
  }

  _Expression expression(int minimum) {
    if (++depth > 64) {
      throw const FormatException('Expression nesting exceeds 64 levels.');
    }
    var left = primary();
    while ((precedence[next] ?? -1) >= minimum) {
      final operator = tokens[index++];
      left = _Binary(left, operator, expression(precedence[operator]! + 1));
    }
    depth--;
    return left;
  }

  _Expression primary() {
    if (const {'!', '-', '+'}.contains(next)) {
      final operator = tokens[index++];
      return _Unary(operator, expression(7));
    }
    if (take('(')) {
      final value = expression(0);
      expect(')');
      return value;
    }
    if (next.isEmpty) throw FormatException('Incomplete expression: $source');
    final token = tokens[index++];
    final number = double.tryParse(token);
    if (number != null) return _Literal(_number(number));
    if (token == 'true' || token == 'false') return _Literal(token == 'true');
    if (token == 'null') return _Literal(null);
    if (token.startsWith('"') || token.startsWith("'")) {
      return _Literal(token.substring(1, token.length - 1));
    }
    if (take('(')) {
      if (!_functions.contains(token)) {
        throw FormatException('Unknown function "$token".');
      }
      final args = <_Expression>[];
      if (!take(')')) {
        do {
          args.add(expression(0));
        } while (take(','));
        expect(')');
      }
      final arity =
          _indicators.contains(token) ||
              const {'rsi', 'min', 'max', 'pow'}.contains(token)
          ? 2
          : token == 'clamp'
          ? 3
          : 1;
      if (args.length != arity) {
        throw FormatException('$token expects $arity argument(s).');
      }
      if ((_indicators.contains(token) || token == 'rsi') &&
          (args.first is! _Variable ||
              !_series.contains((args.first as _Variable).name))) {
        throw FormatException(
          '$token needs open, high, low, close, or volume as its first argument.',
        );
      }
      return _Call(token, args);
    }
    if (!names.contains(token)) {
      throw FormatException(
        'Unknown variable "$token". Define calculations before using them.',
      );
    }
    if (take('[')) {
      if (!_series.contains(token)) {
        throw const FormatException(
          'Only candle series support history offsets.',
        );
      }
      final offset = expression(0);
      expect(']');
      return _Index(token, offset);
    }
    return _Variable(token);
  }
}
