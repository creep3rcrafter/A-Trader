import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:a_trade/market_data/market_data.dart';
import 'package:http/http.dart' as http;

enum AssistantProvider { lmStudio, openAi }

class AssistantConfiguration {
  AssistantConfiguration.fromEnvironment(Map<String, String> environment)
    : openAiApiKey = _nonEmpty(environment['OPENAI_API_KEY']),
      openAiModel = _nonEmpty(environment['OPENAI_MODEL']) ?? 'gpt-5-mini',
      lmStudioModel =
          _nonEmpty(environment['LM_STUDIO_MODEL']) ?? 'google/gemma-4-e4b',
      lmStudioApiToken = _nonEmpty(environment['LM_STUDIO_API_TOKEN']),
      lmStudioEndpoint = _readLmStudioEndpoint(
        environment['LM_STUDIO_BASE_URL'],
      ),
      lmStudioLocalOnlyConfirmed =
          environment['LM_STUDIO_LOCAL_ONLY_CONFIRMED'] == 'true',
      enabledGate = environment['A_TRADER_ASSISTANT_ENABLED'] == 'true',
      termsConfirmed =
          environment['A_TRADER_MODEL_FORWARDING_TERMS_CONFIRMED'] == 'true',
      maximumCalls = _boundedInt(
        environment['A_TRADER_ASSISTANT_MAX_CALLS'],
        fallback: 10,
        minimum: 1,
        maximum: 1000,
      ),
      maximumConcurrentCalls = _boundedInt(
        environment['A_TRADER_ASSISTANT_MAX_CONCURRENT'],
        fallback: 2,
        minimum: 1,
        maximum: 20,
      ),
      maximumInputCharacters = _boundedInt(
        environment['A_TRADER_ASSISTANT_MAX_INPUT_CHARS'],
        fallback: 4000,
        minimum: 128,
        maximum: 12000,
      ),
      maximumOutputTokens = _boundedInt(
        environment['A_TRADER_ASSISTANT_MAX_OUTPUT_TOKENS'],
        fallback: 512,
        minimum: 32,
        maximum: 2048,
      ),
      requestTimeout = Duration(
        seconds: _boundedInt(
          environment['A_TRADER_ASSISTANT_TIMEOUT_SECONDS'],
          fallback: 45,
          minimum: 5,
          maximum: 180,
        ),
      );

  final String? openAiApiKey;
  final String openAiModel;
  final String? lmStudioModel;
  final String? lmStudioApiToken;
  final Uri lmStudioEndpoint;
  final bool lmStudioLocalOnlyConfirmed;
  final bool enabledGate;
  final bool termsConfirmed;
  final int maximumCalls;
  final int maximumConcurrentCalls;
  final int maximumInputCharacters;
  final int maximumOutputTokens;
  final Duration requestTimeout;

  AssistantProvider get selectedProvider => openAiApiKey == null
      ? AssistantProvider.lmStudio
      : AssistantProvider.openAi;

  String? get selectedModel => switch (selectedProvider) {
    AssistantProvider.openAi => openAiModel,
    AssistantProvider.lmStudio => lmStudioModel,
  };

  bool get selectedProviderConfigured =>
      selectedModel?.isNotEmpty == true &&
      (selectedProvider != AssistantProvider.lmStudio ||
          lmStudioLocalOnlyConfirmed && _isLocalModelName(selectedModel!));

  bool get enabled =>
      enabledGate && termsConfirmed && selectedProviderConfigured;

  bool get researchEnabled =>
      enabledGate &&
      termsConfirmed &&
      lmStudioLocalOnlyConfirmed &&
      lmStudioModel != null &&
      _isLocalModelName(lmStudioModel!);

  LmStudioChatClient? createResearchClient({http.Client? httpClient}) =>
      researchEnabled
      ? LmStudioChatClient(
          endpoint: lmStudioEndpoint,
          model: lmStudioModel!,
          apiToken: lmStudioApiToken,
          httpClient: httpClient,
          timeout: requestTimeout,
        )
      : null;

  Map<String, Object?> healthStatus(AssistantProvider provider) {
    final selected = selectedProvider == provider;
    final model = switch (provider) {
      AssistantProvider.lmStudio => lmStudioModel,
      AssistantProvider.openAi => openAiModel,
    };
    final credentialsPresent = switch (provider) {
      AssistantProvider.openAi => openAiApiKey != null,
      AssistantProvider.lmStudio => lmStudioApiToken != null,
    };
    final configured = provider == AssistantProvider.lmStudio
        ? model != null && _isLocalModelName(model)
        : credentialsPresent && model != null;
    return {
      'credentialsPresent': credentialsPresent,
      'enabled': selected && enabled,
      'integrationImplemented': true,
      'termsConfirmed': termsConfirmed,
      'configured': configured,
      'availabilityVerified': false,
      'research': {
        'enabled': researchEnabled,
        'provider': 'lmstudio',
        'model': lmStudioModel,
        'maximumModelTurns': 3,
        'maximumToolExecutions': 4,
      },
      if (provider == AssistantProvider.lmStudio) 'localOnly': true,
      if (provider == AssistantProvider.lmStudio)
        'localOnlyConfirmed': lmStudioLocalOnlyConfirmed,
      if (provider == AssistantProvider.lmStudio &&
          model != null &&
          !_isLocalModelName(model))
        'disabledReason': 'A valid local LM Studio model must be configured.',
      if (provider == AssistantProvider.lmStudio && !lmStudioLocalOnlyConfirmed)
        'disabledReason':
            'Confirm LM Link and remote routing are disabled before enabling LM Studio.',
      'selected': selected,
      'model': ?model,
      if (provider == AssistantProvider.lmStudio)
        'endpoint': lmStudioEndpoint.toString(),
    };
  }

  Map<String, Object?> get health => {
    'supported': true,
    'integrationImplemented': true,
    'enabled': enabled,
    'provider': selectedProvider == AssistantProvider.lmStudio
        ? 'lmstudio'
        : 'openai',
    'model': selectedModel,
    'termsConfirmed': termsConfirmed,
    'availabilityVerified': false,
    'providers': {
      'lmStudio': healthStatus(AssistantProvider.lmStudio),
      'openAi': healthStatus(AssistantProvider.openAi),
    },
    'limits': {
      'maximumCalls': maximumCalls,
      'maximumConcurrentCalls': maximumConcurrentCalls,
      'maximumInputCharacters': maximumInputCharacters,
      'maximumOutputTokens': maximumOutputTokens,
      'timeoutSeconds': requestTimeout.inSeconds,
    },
  };

  AssistantModelClient? createModelClient({http.Client? httpClient}) {
    if (!enabled) return null;
    return switch (selectedProvider) {
      AssistantProvider.openAi => OpenAiResponsesClient(
        apiKey: openAiApiKey!,
        model: openAiModel,
        httpClient: httpClient,
        timeout: requestTimeout,
      ),
      AssistantProvider.lmStudio => LmStudioChatClient(
        endpoint: lmStudioEndpoint,
        model: lmStudioModel!,
        apiToken: lmStudioApiToken,
        httpClient: httpClient,
        timeout: requestTimeout,
      ),
    };
  }
}

abstract interface class AssistantModelClient {
  AssistantProvider get provider;
  String get model;
  Future<String> generate(String input, {required int maximumOutputTokens});
}

class OpenAiResponsesClient implements AssistantModelClient {
  OpenAiResponsesClient({
    required String apiKey,
    required this.model,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 45),
  }) : _httpClient = httpClient ?? http.Client(),
       _ownsHttpClient = httpClient == null {
    _apiKey = apiKey;
  }

  late final String _apiKey;
  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final Duration timeout;

  @override
  final String model;

  @override
  AssistantProvider get provider => AssistantProvider.openAi;

  @override
  Future<String> generate(
    String input, {
    required int maximumOutputTokens,
  }) async {
    try {
      final request =
          http.Request('POST', Uri.https('api.openai.com', '/v1/responses'))
            ..followRedirects = false
            ..headers.addAll({
              HttpHeaders.authorizationHeader: 'Bearer $_apiKey',
              HttpHeaders.contentTypeHeader: 'application/json',
            })
            ..body = jsonEncode({
              'model': model,
              'input': input,
              'max_output_tokens': maximumOutputTokens,
              'store': false,
            });
      final response = await _sendBounded(
        _httpClient,
        request,
        timeout: timeout,
        provider: 'OpenAI',
      );
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const AssistantModelException(
          'The configured OpenAI service returned an invalid response.',
        );
      }
      final text = _openAiOutputText(decoded);
      if (text.isEmpty) {
        throw const AssistantModelException(
          'The configured OpenAI service returned no explanation.',
        );
      }
      return text;
    } on AssistantModelException {
      rethrow;
    } on TimeoutException {
      throw const AssistantModelException(
        'The configured OpenAI service timed out.',
      );
    } on http.ClientException {
      throw const AssistantModelException(
        'The configured OpenAI service is unreachable.',
      );
    } on FormatException {
      throw const AssistantModelException(
        'The configured OpenAI service returned an invalid response.',
      );
    }
  }

  void close() {
    if (_ownsHttpClient) _httpClient.close();
  }
}

class LmStudioChatClient implements AssistantModelClient {
  LmStudioChatClient({
    required this.endpoint,
    required this.model,
    String? apiToken,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 45),
  }) : _apiToken = _nonEmpty(apiToken),
       _httpClient = httpClient ?? http.Client(),
       _ownsHttpClient = httpClient == null {
    if (!_isLocalModelName(model)) {
      throw const FormatException('A valid local LM Studio model is required.');
    }
    if (!endpoint.hasAuthority ||
        !const {'http', 'https'}.contains(endpoint.scheme) ||
        !const {'/v1', '/v1/'}.contains(endpoint.path) ||
        !_isLoopback(endpoint) ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment) {
      throw ArgumentError.value(
        endpoint,
        'endpoint',
        'LM Studio endpoint must be a local loopback URL.',
      );
    }
  }

  final Uri endpoint;
  final String? _apiToken;
  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final Duration timeout;

  @override
  final String model;

  @override
  AssistantProvider get provider => AssistantProvider.lmStudio;

  @override
  Future<String> generate(
    String input, {
    required int maximumOutputTokens,
  }) async {
    final message = await complete(
      messages: [
        {'role': 'user', 'content': input},
      ],
      maximumOutputTokens: maximumOutputTokens,
    );
    final content = message['content'];
    if (content is! String || content.trim().isEmpty) {
      throw const AssistantModelException(
        'The configured LM Studio service returned no explanation.',
      );
    }
    return content;
  }

  Future<Map<String, dynamic>> complete({
    required List<Map<String, Object?>> messages,
    required int maximumOutputTokens,
    List<Map<String, Object?>>? tools,
    bool finalTurn = false,
    void Function()? beforeModelCall,
  }) async {
    try {
      final modelsRequest = http.Request(
        'GET',
        endpoint.replace(
          path: '${endpoint.path.replaceFirst(RegExp(r'/$'), '')}/models',
        ),
      )..followRedirects = false;
      if (_apiToken != null) {
        modelsRequest.headers[HttpHeaders.authorizationHeader] =
            'Bearer $_apiToken';
      }
      final modelsResponse = await _sendBounded(
        _httpClient,
        modelsRequest,
        timeout: timeout,
        provider: 'LM Studio',
      );
      final models = jsonDecode(modelsResponse.body);
      if (models is! Map<String, dynamic> || models['data'] is! List) {
        throw const AssistantModelException(
          'The configured LM Studio service returned an invalid model list.',
        );
      }
      final installedModels = (models['data'] as List)
          .whereType<Map<String, dynamic>>()
          .where((entry) => entry['id'] == model)
          .toList();
      if (installedModels.isEmpty) {
        throw const AssistantModelException(
          'The configured LM Studio model is not available locally.',
        );
      }
      for (final installed in installedModels) {
        _rejectRemoteModelMetadata(installed);
        if (installed.containsKey('remote_host') ||
            installed.containsKey('remote_model')) {
          throw const AssistantModelException(
            'Remote or hosted local-provider models are not permitted.',
          );
        }
      }
      final request =
          http.Request(
              'POST',
              endpoint.replace(
                path:
                    '${endpoint.path.replaceFirst(RegExp(r'/$'), '')}/chat/completions',
              ),
            )
            ..followRedirects = false
            ..headers[HttpHeaders.contentTypeHeader] = 'application/json'
            ..body = jsonEncode({
              'model': model,
              'messages': messages,
              'stream': false,
              'max_tokens': maximumOutputTokens,
              'tools': ?tools,
              if (tools != null) 'tool_choice': finalTurn ? 'none' : 'auto',
            });
      if (_apiToken != null) {
        request.headers[HttpHeaders.authorizationHeader] = 'Bearer $_apiToken';
      }
      beforeModelCall?.call();
      final response = await _sendBounded(
        _httpClient,
        request,
        timeout: timeout,
        provider: 'LM Studio',
      );
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic> || decoded['choices'] is! List) {
        throw const AssistantModelException(
          'The configured LM Studio service returned an invalid response.',
        );
      }
      _rejectRemoteModelMetadata(decoded);
      final responseModel = decoded['model'];
      if (responseModel is! String || responseModel != model) {
        throw const AssistantModelException(
          'The configured LM Studio service returned an invalid local response.',
        );
      }
      final choices = decoded['choices'] as List;
      final first = choices.isEmpty ? null : choices.first;
      final message = first is Map<String, dynamic> ? first['message'] : null;
      if (message is! Map<String, dynamic> ||
          (message['role'] != null && message['role'] != 'assistant') ||
          first['finish_reason'] == 'length') {
        throw const AssistantModelException(
          'The configured LM Studio service returned an invalid or truncated message.',
        );
      }
      return message;
    } on AssistantModelException {
      rethrow;
    } on TimeoutException {
      throw const AssistantModelException(
        'The configured LM Studio service timed out.',
      );
    } on http.ClientException {
      throw const AssistantModelException(
        'The configured LM Studio service is unreachable.',
      );
    } on FormatException {
      throw const AssistantModelException(
        'The configured LM Studio service returned an invalid response.',
      );
    }
  }

  void close() {
    if (_ownsHttpClient) _httpClient.close();
  }
}

class AssistantService {
  AssistantService({
    required this.configuration,
    required this.marketData,
    required this.modelClient,
    required this.marketDataProvider,
    required this.marketDataCoverage,
    AssistantCallBudget? callBudget,
    DateTime Function()? clock,
  }) : _callBudget =
           callBudget ?? AssistantCallBudget(configuration: configuration),
       _clock = clock ?? DateTime.now;

  final AssistantConfiguration configuration;
  final MarketDataRepository? marketData;
  final AssistantModelClient? modelClient;
  final String marketDataProvider;
  final String marketDataCoverage;
  final AssistantCallBudget _callBudget;
  final DateTime Function() _clock;

  Future<Map<String, Object?>> explain({
    required String symbol,
    required String prompt,
  }) async {
    if (!configuration.enabled || modelClient == null) {
      throw const AssistantRequestException(
        HttpStatus.serviceUnavailable,
        'Assistant explanations are disabled by configuration.',
      );
    }
    if (marketData == null) {
      throw const AssistantRequestException(
        HttpStatus.serviceUnavailable,
        'Market-data provider is not configured.',
      );
    }
    if (!RegExp(r'^[A-Z0-9.-]{1,15}$').hasMatch(symbol)) {
      throw const AssistantRequestException(
        HttpStatus.badRequest,
        'symbol must be a valid ticker.',
      );
    }
    if (prompt.trim().isEmpty ||
        prompt.length > configuration.maximumInputCharacters) {
      throw const AssistantRequestException(
        HttpStatus.badRequest,
        'prompt must be non-empty and within the configured input limit.',
      );
    }

    _callBudget.beginRequest();
    try {
      final quote = await marketData!.latestQuote(symbol);
      if (quote == null ||
          quote.symbol != symbol ||
          quote.provider.name != marketDataProvider ||
          quote.lastPrice == null) {
        throw const AssistantRequestException(
          HttpStatus.badGateway,
          'The configured market-data provider returned no usable quote.',
        );
      }
      final provenance = {
        'symbol': quote.symbol,
        'provider': quote.provider.name,
        'feed': quote.feed.name,
        'coverage': marketDataCoverage,
        'quote': quote.toJson(
          now: _clock().toUtc(),
          maximumAge: const Duration(minutes: 1),
        ),
      };
      final input = jsonEncode({
        'task':
            'Explain the provided market quote for the requested symbol. '
            'Use only the supplied quote as market evidence. Do not invent '
            'prices, calculate or suggest entry/exit prices, make a trade, or '
            'claim facts not present in the quote. Make clear that this is '
            'informational and not financial advice.',
        'symbol': symbol,
        'marketEvidence': provenance,
        'userPrompt': prompt,
      });
      if (utf8.encode(input).length >
          configuration.maximumInputCharacters * 4 + 4096) {
        throw const AssistantRequestException(
          HttpStatus.badRequest,
          'The resulting request exceeds the configured input limit.',
        );
      }
      _callBudget.consumeAdditionalCall();
      final explanation = await modelClient!.generate(
        input,
        maximumOutputTokens: configuration.maximumOutputTokens,
      );
      final boundedExplanation = explanation.trim();
      if (boundedExplanation.isEmpty || boundedExplanation.length > 12000) {
        throw const AssistantModelException(
          'The configured model returned an invalid explanation.',
        );
      }
      return {
        'explanation': boundedExplanation,
        'provider': switch (modelClient!.provider) {
          AssistantProvider.lmStudio => 'lmstudio',
          AssistantProvider.openAi => 'openai',
        },
        'model': modelClient!.model,
        'generatedAt': _clock().toUtc().toIso8601String(),
        'provenance': provenance,
        'inputs': {
          'symbol': symbol,
          'quote': provenance['quote'],
          'prompt': {
            'characters': prompt.length,
            'utf8Bytes': utf8.encode(prompt).length,
            'contentIncluded': false,
          },
        },
        'usage': {
          'requestCharacters': input.length,
          'requestUtf8Bytes': utf8.encode(input).length,
          'explanationCharacters': boundedExplanation.length,
          'maximumOutputTokens': configuration.maximumOutputTokens,
          'providerTokenUsageAvailable': false,
          'callsStarted': _callBudget.callsStarted,
          'maximumCalls': configuration.maximumCalls,
          'scope': 'serverProcess',
        },
      };
    } on AssistantModelException {
      rethrow;
    } finally {
      _callBudget.endRequest();
    }
  }
}

class AssistantCallBudget {
  AssistantCallBudget({required this.configuration});

  final AssistantConfiguration configuration;
  int callsStarted = 0;
  int _activeRequests = 0;

  void beginRequest() {
    if (_activeRequests >= configuration.maximumConcurrentCalls) {
      throw const AssistantRequestException(
        HttpStatus.tooManyRequests,
        'Assistant is at its configured concurrency limit.',
      );
    }
    if (callsStarted >= configuration.maximumCalls) {
      throw const AssistantRequestException(
        HttpStatus.tooManyRequests,
        'Assistant call limit has been reached.',
      );
    }
    _activeRequests++;
  }

  void consumeAdditionalCall() => _consumeCall();

  void endRequest() {
    if (_activeRequests > 0) _activeRequests--;
  }

  void _consumeCall() {
    if (callsStarted >= configuration.maximumCalls) {
      throw const AssistantRequestException(
        HttpStatus.tooManyRequests,
        'Assistant call limit has been reached.',
      );
    }
    callsStarted++;
  }
}

class AssistantModelException implements Exception {
  const AssistantModelException(this.message);
  final String message;
}

class AssistantRequestException implements Exception {
  const AssistantRequestException(this.statusCode, this.message);
  final int statusCode;
  final String message;
}

String _openAiOutputText(Map<String, dynamic> response) {
  final output = response['output'];
  if (output is! List) return '';
  final texts = <String>[];
  for (final item in output) {
    if (item is! Map<String, dynamic> || item['type'] != 'message') continue;
    final content = item['content'];
    if (content is! List) continue;
    for (final part in content) {
      if (part is Map<String, dynamic> &&
          part['type'] == 'output_text' &&
          part['text'] is String) {
        texts.add(part['text'] as String);
      }
    }
  }
  return texts.join('\n').trim();
}

String? _nonEmpty(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

Uri _readLmStudioEndpoint(String? value) {
  final endpoint = Uri.tryParse(_nonEmpty(value) ?? 'http://127.0.0.1:1234/v1');
  if (endpoint == null ||
      !endpoint.hasAuthority ||
      (endpoint.scheme != 'http' && endpoint.scheme != 'https') ||
      !_isLoopback(endpoint) ||
      endpoint.userInfo.isNotEmpty ||
      endpoint.hasQuery ||
      endpoint.hasFragment ||
      !const {'/v1', '/v1/'}.contains(endpoint.path)) {
    throw const FormatException(
      'LM_STUDIO_BASE_URL must be an HTTP loopback URL ending in /v1.',
    );
  }
  return endpoint;
}

bool _isLoopback(Uri uri) {
  if (uri.host.toLowerCase() == 'localhost') return true;
  final address = InternetAddress.tryParse(uri.host);
  return address?.isLoopback ?? false;
}

bool _isLocalModelName(String model) =>
    model.isNotEmpty &&
    model.length <= 200 &&
    RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._:/-]*$').hasMatch(model) &&
    !model.contains('://');

void _rejectRemoteModelMetadata(Object? value) {
  if (value is Map<String, dynamic>) {
    for (final entry in value.entries) {
      if (const {'remote_host', 'remote_model', 'cloud'}.contains(entry.key) &&
          entry.value != null &&
          entry.value != false &&
          entry.value != '') {
        throw const AssistantModelException(
          'Remote or hosted local-provider models are not permitted.',
        );
      }
      if ((entry.key == 'model' || entry.key == 'name') &&
          entry.value is String &&
          !_isLocalModelName(entry.value as String)) {
        throw const AssistantModelException(
          'Remote or hosted local-provider models are not permitted.',
        );
      }
      _rejectRemoteModelMetadata(entry.value);
    }
  } else if (value is List) {
    for (final item in value) {
      _rejectRemoteModelMetadata(item);
    }
  }
}

int _boundedInt(
  String? value, {
  required int fallback,
  required int minimum,
  required int maximum,
}) {
  if (value == null || value.trim().isEmpty) return fallback;
  final parsed = int.tryParse(value.trim());
  if (parsed == null || parsed < minimum || parsed > maximum) {
    throw FormatException(
      'Assistant configuration value must be between $minimum and $maximum.',
    );
  }
  return parsed;
}

Future<http.Response> _sendBounded(
  http.Client client,
  http.Request request, {
  required Duration timeout,
  required String provider,
}) async {
  final streamed = await client.send(request).timeout(timeout);
  if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
    await streamed.stream.listen((_) {}).cancel();
    throw AssistantModelException(
      'The configured $provider service rejected the request.',
    );
  }
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in streamed.stream.timeout(timeout)) {
    if (bytes.length + chunk.length > 65536) {
      throw AssistantModelException(
        'The configured $provider service returned an oversized response.',
      );
    }
    bytes.add(chunk);
  }
  return http.Response.bytes(
    bytes.takeBytes(),
    streamed.statusCode,
    headers: streamed.headers,
    request: streamed.request,
    isRedirect: streamed.isRedirect,
    persistentConnection: streamed.persistentConnection,
    reasonPhrase: streamed.reasonPhrase,
  );
}
