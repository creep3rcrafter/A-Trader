import 'dart:convert';

import 'package:http/http.dart' as http;

import '../market_data/local_market_data_service.dart';
import 'local_service_url.dart';
import 'research_url.dart';

class AssistantException implements Exception {
  const AssistantException(this.message);
  final String message;
}

class AssistantExplanation {
  const AssistantExplanation({
    required this.text,
    required this.provider,
    required this.model,
    this.sources = const [],
    this.toolsUsed = const [],
    this.limitations = const [],
  });

  final String text;
  final String provider;
  final String model;
  final List<ResearchSource> sources;
  final List<String> toolsUsed;
  final List<String> limitations;
}

class ResearchSource {
  const ResearchSource({
    required this.url,
    required this.title,
    required this.publishedAt,
    required this.retrievedAt,
    this.kind,
    this.provider,
  });

  final Uri url;
  final String title;
  final String? publishedAt;
  final DateTime retrievedAt;
  final String? kind;
  final String? provider;
}

class AssistantService {
  AssistantService({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  void close() {
    if (_ownsClient) _client.close();
  }

  Future<AssistantExplanation> explain(
    String backendUrl,
    String symbol,
    String prompt,
  ) => _request(backendUrl, symbol, prompt);

  Future<AssistantExplanation> research(
    String backendUrl,
    String symbol,
    String prompt, {
    required int holdingDays,
    int lookbackDays = 7,
  }) {
    if (holdingDays < 1 ||
        holdingDays > 365 ||
        lookbackDays < 1 ||
        lookbackDays > 30) {
      throw const AssistantException(
        'Use a 1-365 day horizon and 1-30 day research window.',
      );
    }
    return _request(
      backendUrl,
      symbol,
      prompt,
      research: true,
      holdingDays: holdingDays,
      lookbackDays: lookbackDays,
    );
  }

  Future<AssistantExplanation> _request(
    String backendUrl,
    String symbol,
    String prompt, {
    bool research = false,
    int? holdingDays,
    int? lookbackDays,
  }) async {
    final uri = Uri.tryParse(backendUrl);
    if (uri == null || !isLocalServiceUri(uri)) {
      throw const AssistantException(
        'Use the local service or this web app\'s server URL.',
      );
    }
    if (prompt.trim().isEmpty || prompt.length > 4000) {
      throw const AssistantException(
        'Use an analysis prompt of 1-4000 characters in Settings.',
      );
    }
    String ticker;
    try {
      ticker = normalizeMarketSymbol(symbol);
    } on LocalMarketDataException {
      throw const AssistantException('Invalid stock ticker.');
    }
    late http.Response response;
    try {
      final request =
          http.Request(
              'POST',
              uri.replace(
                path: research
                    ? '/api/v1/assistant/research'
                    : '/api/v1/assistant/explain',
                query: '',
                fragment: '',
              ),
            )
            ..followRedirects = false
            ..headers['Content-Type'] = 'application/json'
            ..body = jsonEncode({
              'symbol': ticker,
              'prompt': prompt,
              if (research) 'holdingDays': holdingDays,
              if (research) 'lookbackDays': lookbackDays,
            });
      response = await http.Response.fromStream(
        await _client.send(request).timeout(const Duration(seconds: 150)),
      ).timeout(const Duration(seconds: 150));
    } on Exception {
      throw const AssistantException(
        'Could not reach the assistant. Check the backend and local LM Studio server.',
      );
    }
    if (response.statusCode != 200) {
      throw AssistantException(switch (response.statusCode) {
        401 => 'Session expired. Reload this page to sign in again.',
        403 =>
          'Analysis is denied. Check server origin and model data-use permission.',
        404 => 'No verified quote is available for this stock.',
        429 => 'Assistant call limit reached. Try again later.',
        503 =>
          research
              ? 'Local research unavailable. Configure LM Studio and confirm local-only and data-processing permissions on the server.'
              : 'Assistant unavailable. Configure a local LM Studio model or OpenAI and enable analysis on the server.',
        _ => 'Assistant request failed. Check server model configuration.',
      });
    }
    try {
      final json = jsonDecode(response.body);
      if (json is! Map<String, dynamic> ||
          json['explanation'] is! String ||
          (json['explanation'] as String).trim().isEmpty ||
          (json['explanation'] as String).length > 16000 ||
          !['lmstudio', 'openai'].contains(json['provider']) ||
          json['model'] is! String ||
          (json['model'] as String).trim().isEmpty ||
          (json['model'] as String).length > 200) {
        throw const FormatException();
      }
      final sources = <ResearchSource>[];
      final toolsUsed = <String>[];
      final limitations = <String>[];
      if (research) {
        if (json['provider'] != 'lmstudio' ||
            json['sources'] is! List ||
            (json['sources'] as List).length > 30 ||
            json['toolsUsed'] is! List ||
            (json['toolsUsed'] as List).length > 4 ||
            json['limitations'] is! List ||
            (json['limitations'] as List).length > 30) {
          throw const FormatException();
        }
        for (final source in json['sources'] as List) {
          if (source is! Map<String, dynamic> ||
              source['url'] is! String ||
              source['title'] is! String ||
              (source['title'] as String).isEmpty ||
              (source['title'] as String).length > 500 ||
              source['retrievedAt'] is! String ||
              (source['publishedAt'] != null &&
                  source['publishedAt'] is! String)) {
            throw const FormatException();
          }
          final uri = Uri.tryParse(source['url'] as String);
          final retrieved = DateTime.tryParse(source['retrievedAt'] as String);
          final published = source['publishedAt'] as String?;
          if (uri == null ||
              uri.scheme != 'https' ||
              uri.host.isEmpty ||
              uri.userInfo.isNotEmpty ||
              uri.hasFragment ||
              !(source['kind'] == 'webSearch'
                  ? source['provider'] == 'duckduckgo' &&
                        source['publishedAt'] == null &&
                        (json['toolsUsed'] as List).contains(
                          'search_public_web',
                        ) &&
                        isPublicResearchUrl(uri)
                  : source['kind'] == null &&
                        source['provider'] == null &&
                        _isResearchSource(uri, ticker)) ||
              retrieved == null ||
              !RegExp(
                r'(Z|[+-]\d{2}:\d{2})$',
              ).hasMatch(source['retrievedAt'] as String) ||
              (published != null &&
                  (published.length > 40 ||
                      DateTime.tryParse(published) == null)) ||
              (source['url'] as String).length > 2000) {
            throw const FormatException();
          }
          sources.add(
            ResearchSource(
              url: uri,
              title: source['title'] as String,
              publishedAt: source['publishedAt'] as String?,
              retrievedAt: retrieved.toUtc(),
              kind: source['kind'] as String?,
              provider: source['provider'] as String?,
            ),
          );
        }
        for (final tool in json['toolsUsed'] as List) {
          if (tool is! String ||
              ![
                'get_market_quote',
                'get_daily_bars',
                'get_sec_filings',
                'get_technical_indicators',
                'search_public_web',
              ].contains(tool)) {
            throw const FormatException();
          }
          toolsUsed.add(tool);
        }
        if (sources.isNotEmpty && toolsUsed.isEmpty) {
          throw const FormatException();
        }
        for (final limitation in json['limitations'] as List) {
          if (limitation is! String || limitation.length > 2000) {
            throw const FormatException();
          }
          limitations.add(limitation);
        }
      }
      return AssistantExplanation(
        text: json['explanation'] as String,
        provider: json['provider'] as String,
        model: json['model'] as String,
        sources: List.unmodifiable(sources),
        toolsUsed: List.unmodifiable(toolsUsed),
        limitations: List.unmodifiable(limitations),
      );
    } on FormatException {
      throw const AssistantException('Invalid assistant response.');
    }
  }

  bool _isResearchSource(Uri uri, String symbol) {
    if (uri.port != 443) return false;
    return switch (uri.host) {
      'www.sec.gov' =>
        RegExp(
              r'^/Archives/edgar/data/\d+/[a-zA-Z0-9._/-]+$',
            ).hasMatch(uri.path) &&
            !uri.path.split('/').contains('..') &&
            !uri.hasQuery,
      'data.alpaca.markets' =>
        {
              '/v2/stocks/$symbol/trades/latest',
              '/v2/stocks/$symbol/quotes/latest',
              '/v2/stocks/$symbol/bars',
            }.contains(uri.path) &&
            uri.queryParameters['feed'] == 'iex',
      'api.schwabapi.com' =>
        uri.port == 443 &&
            ((uri.path == '/marketdata/v1/quotes' &&
                    uri.queryParametersAll.length == 1 &&
                    uri.queryParametersAll['symbols']?.length == 1 &&
                    uri.queryParameters['symbols'] == symbol) ||
                (uri.path == '/marketdata/v1/pricehistory' &&
                    uri.queryParametersAll.length == 1 &&
                    uri.queryParametersAll['symbol']?.length == 1 &&
                    uri.queryParameters['symbol'] == symbol)),
      'api.twelvedata.com' =>
        {'/quote', '/time_series'}.contains(uri.path) &&
            uri.queryParameters['symbol'] == symbol &&
            !uri.queryParameters.containsKey('apikey'),
      _ => false,
    };
  }
}
