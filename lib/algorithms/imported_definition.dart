import '../strategy_api.dart';

/// Serializable metadata shared with the dashboard; it never executes source.
class ImportedAlgorithmDefinition implements TradingStrategy {
  ImportedAlgorithmDefinition.fromJson(Map<String, dynamic> json)
    : id = _text(json, 'id'),
      name = _text(json, 'name'),
      description = _text(json, 'description'),
      warmupBars = _integer(json['warmupBars'], 'warmupBars', 1, 10000),
      parameters = _parameters(json['parameters']);

  @override
  final String id;
  @override
  final String name;
  @override
  final String description;
  @override
  final int warmupBars;
  @override
  final List<StrategyParameter> parameters;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'warmupBars': warmupBars,
    'parameters': {
      for (final p in parameters)
        p.name: {
          'label': p.label ?? p.name,
          'unit': p.unit,
          'default': p.defaultValue,
          'min': p.minimum,
          'max': p.maximum,
        },
    },
  };

  @override
  StrategySignal evaluate(StrategyContext context) => const StrategySignal(
    TradeAction.wait,
    'Imported algorithm decisions run in the local backend.',
  );

  static String _text(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! String || value.trim().isEmpty || value.length > 4000) {
      throw FormatException('Provide a nonempty $key (up to 4000 characters).');
    }
    if (key == 'id' && !RegExp(r'^[a-z][a-z0-9_]{0,79}$').hasMatch(value)) {
      throw const FormatException(
        'Algorithm id must use lowercase letters, numbers, and underscores, starting with a letter (up to 80 characters).',
      );
    }
    return value.trim();
  }

  static int _integer(Object? value, String name, int min, int max) {
    if (value is! num ||
        !value.isFinite ||
        value != value.roundToDouble() ||
        value < min ||
        value > max) {
      throw FormatException('$name must be an integer from $min to $max.');
    }
    return value.toInt();
  }

  static List<StrategyParameter> _parameters(Object? value) {
    if (value is! Map || value.length > 64) {
      throw const FormatException(
        'parameters must be an object with at most 64 variables.',
      );
    }
    return [
      for (final entry in value.entries) _parameter(entry.key, entry.value),
    ];
  }

  static StrategyParameter _parameter(Object? key, Object? raw) {
    if (key is! String ||
        !RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]{0,79}$').hasMatch(key) ||
        raw is! Map) {
      throw const FormatException(
        'Each parameter needs a valid variable name and an object definition.',
      );
    }
    double number(String field) {
      final value = raw[field];
      if (value is! num || !value.isFinite) {
        throw FormatException('$key.$field must be a finite number.');
      }
      return value.toDouble();
    }

    final min = number('min'), max = number('max'), initial = number('default');
    if (min > max || initial < min || initial > max) {
      throw FormatException('$key.default must be between min and max.');
    }
    if (raw['round'] != null && raw['round'] is! bool) {
      throw FormatException('$key.round must be true or false.');
    }
    if (raw['round'] == true &&
        (min != min.roundToDouble() ||
            max != max.roundToDouble() ||
            initial != initial.roundToDouble())) {
      throw FormatException(
        '$key needs integer min, max, and default when round is true.',
      );
    }
    return StrategyParameter(
      name: key,
      label: raw['label']?.toString() ?? key,
      unit: raw['unit']?.toString() ?? '',
      defaultValue: initial,
      minimum: min,
      maximum: max,
    );
  }
}
