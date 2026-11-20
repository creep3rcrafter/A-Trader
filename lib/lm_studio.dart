/// OpenAI-compatible LM Studio client. Network failures are returned explicitly
/// so callers can log WAIT while built-in strategies continue independently.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'simulator.dart';
import 'algorithms/lm_selector.dart';

export 'algorithms/lm_selector.dart'
    show LmStudioSelection, LmStudioSelectorStrategy;

class LmStudioClient {
  LmStudioClient({
    required this.baseUrl,
    required this.model,
    HttpClient? client,
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? HttpClient();

  final String baseUrl;
  final String model;
  final Duration? timeout;
  final HttpClient _client;

  Future<List<String>> discoverModels() async {
    final response = await _request('GET', '/v1/models');
    final data = response['data'] as List<dynamic>? ?? [];
    return data
        .whereType<Map<String, dynamic>>()
        .map((item) => item['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toList();
  }

  /// Confirms that the configured server executes a supplied read-only tool.
  Future<void> testToolCalling() async {
    if (model.isEmpty) throw ArgumentError('Choose an LM Studio model first.');
    final response = await _request(
      'POST',
      '/v1/chat/completions',
      body: {
        'model': model,
        'temperature': 0,
        'tool_choice': 'required',
        'tools': [
          {
            'type': 'function',
            'function': {
              'name': 'confirm_tool_calling',
              'description': 'Return a fixed health-check result.',
              'parameters': {
                'type': 'object',
                'properties': {
                  'ready': {'type': 'boolean'},
                },
                'required': ['ready'],
                'additionalProperties': false,
              },
            },
          },
        ],
        'messages': [
          {
            'role': 'user',
            'content': 'Call the confirm_tool_calling tool with ready=true.',
          },
        ],
      },
    );
    final choices = response['choices'] as List<dynamic>? ?? [];
    if (choices.isEmpty) {
      throw StateError('LM Studio returned no completion choices.');
    }
    final message =
        (choices.first as Map<String, dynamic>)['message']
            as Map<String, dynamic>?;
    final calls = message?['tool_calls'] as List<dynamic>? ?? [];
    if (!calls.any((call) {
      final function =
          (call as Map<String, dynamic>)['function'] as Map<String, dynamic>?;
      return function?['name'] == 'confirm_tool_calling';
    })) {
      throw StateError('The selected model did not call the supplied tool.');
    }
  }

  /// Asks the model to select one registry strategy tool or explicitly WAIT.
  /// Tool arguments are validated and are never interpreted as an order.
  Future<LmStudioSelection> selectStrategy({
    required Set<String> eligibleStrategyIds,
    required Map<String, Object?> snapshot,
  }) async {
    if (model.isEmpty) throw ArgumentError('Choose an LM Studio model first.');
    final tools = strategyToolSchemas().where((tool) {
      final function = tool['function'] as Map<String, Object?>;
      final name = function['name'] as String;
      return eligibleStrategyIds.contains(name.substring('inspect_'.length));
    }).toList();
    tools.add(_waitToolSchema);
    if (eligibleStrategyIds.isEmpty) {
      throw StateError('No strategy tools are eligible for selection.');
    }
    final response = await _request(
      'POST',
      '/v1/chat/completions',
      body: {
        'model': model,
        'temperature': 0,
        'tool_choice': 'required',
        'tools': tools,
        'messages': [
          {
            'role': 'system',
            'content':
                'Choose one eligible strategy tool for the current market '
                'snapshot, or call wait. Tools only evaluate strategy rules; '
                'never place or request orders. Explain the choice briefly.',
          },
          {'role': 'user', 'content': jsonEncode(snapshot)},
        ],
      },
    );
    final choices = response['choices'] as List<dynamic>? ?? [];
    if (choices.isEmpty) {
      throw StateError('LM Studio returned no completion choices.');
    }
    final message =
        (choices.first as Map<String, dynamic>)['message']
            as Map<String, dynamic>?;
    final calls = message?['tool_calls'] as List<dynamic>? ?? [];
    if (calls.length != 1) {
      throw StateError(
        'LM Studio must call exactly one strategy tool or wait.',
      );
    }
    final call = calls.single as Map<String, dynamic>;
    final function = call['function'] as Map<String, dynamic>?;
    final toolName = function?['name']?.toString() ?? '';
    final rawArguments = function?['arguments'];
    final decodedArguments = rawArguments is String
        ? jsonDecode(rawArguments)
        : rawArguments;
    if (decodedArguments is! Map<String, dynamic>) {
      throw const FormatException(
        'LM Studio tool arguments were not an object.',
      );
    }
    final reason = (decodedArguments['reason'] ?? message?['content'] ?? '')
        .toString()
        .trim();
    if (toolName == 'wait') {
      return LmStudioSelection(
        toolName: toolName,
        reason: reason.isEmpty ? 'Model selected WAIT.' : reason,
      );
    }
    if (!toolName.startsWith('inspect_')) {
      throw StateError('LM Studio called an unknown strategy tool.');
    }
    final strategyId = toolName.substring('inspect_'.length);
    if (!eligibleStrategyIds.contains(strategyId)) {
      throw StateError('LM Studio selected an ineligible strategy.');
    }
    if (decodedArguments['symbol'] != snapshot['currentSymbol']) {
      throw StateError(
        'LM Studio selected a symbol outside the current decision.',
      );
    }
    final strategy = StrategyRegistry.byId(strategyId);
    final parameters = <String, double>{
      for (final parameter in strategy.parameters)
        parameter.name: parameter.defaultValue,
    };
    for (final parameter in strategy.parameters) {
      final value = decodedArguments[parameter.name];
      if (value == null) continue;
      if (value is! num ||
          !value.toDouble().isFinite ||
          value < parameter.minimum ||
          value > parameter.maximum) {
        throw FormatException(
          'LM Studio returned an invalid ${parameter.name} for $strategyId.',
        );
      }
      parameters[parameter.name] = value.toDouble();
    }
    return LmStudioSelection(
      strategyId: strategyId,
      parameters: parameters,
      toolName: toolName,
      reason: reason.isEmpty ? 'Model selected ${strategy.name}.' : reason,
    );
  }

  List<Map<String, Object?>> strategyToolSchemas() => [
    for (final strategy in StrategyRegistry.all)
      {
        'type': 'function',
        'function': {
          'name': 'inspect_${strategy.id}',
          'description': 'Evaluate ${strategy.name}: ${strategy.description}',
          'parameters': {
            'type': 'object',
            'properties': {
              'symbol': {
                'type': 'string',
                'description': 'A symbol in the active live watchlist.',
              },
              'reason': {
                'type': 'string',
                'description': 'A concise plain-English reason for selection.',
              },
              for (final parameter in strategy.parameters)
                parameter.name: {
                  'type': 'number',
                  'description':
                      '${parameter.name} in ${parameter.unit}; allowed ${parameter.minimum} to ${parameter.maximum}; default ${parameter.defaultValue}.',
                },
            },
            'required': ['symbol'],
            'additionalProperties': false,
          },
        },
      },
  ];

  static const Map<String, Object?> _waitToolSchema = {
    'type': 'function',
    'function': {
      'name': 'wait',
      'description': 'Choose no strategy for this decision.',
      'parameters': {
        'type': 'object',
        'properties': {
          'reason': {'type': 'string'},
        },
        'additionalProperties': false,
      },
    },
  };

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    final base = Uri.parse(baseUrl);
    final uri = base.replace(
      path: '${base.path.replaceFirst(RegExp(r'/$'), '')}$path',
      query: null,
    );
    final request = method == 'GET'
        ? await _withTimeout(_client.getUrl(uri))
        : await _withTimeout(_client.postUrl(uri));
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await _withTimeout(request.close());
    final text = await _withTimeout(utf8.decoder.bind(response).join());
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'LM Studio returned HTTP ${response.statusCode}.',
        uri: uri,
      );
    }
    final value = jsonDecode(text);
    if (value is! Map<String, dynamic>) {
      throw const FormatException('LM Studio response was not a JSON object.');
    }
    return value;
  }

  Future<T> _withTimeout<T>(Future<T> result) {
    final limit = timeout;
    return limit == null ? result : result.timeout(limit);
  }

  void close() => _client.close(force: true);
}
