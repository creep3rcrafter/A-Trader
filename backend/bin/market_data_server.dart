import 'dart:io';

import 'package:a_trade/market_data/alpaca_market_data_client.dart';
import 'package:a_trade/market_data/market_data.dart';
import 'package:a_trade/market_data/twelve_data_market_data_client.dart';

// ignore: avoid_relative_lib_imports
import '../lib/assistant.dart';
// ignore: avoid_relative_lib_imports
import '../lib/daily_indicator_service.dart';
// ignore: avoid_relative_lib_imports
import '../lib/server.dart';
// ignore: avoid_relative_lib_imports
import '../lib/lan_data_policy.dart';
// ignore: avoid_relative_lib_imports
import '../lib/research.dart';
// ignore: avoid_relative_lib_imports
import '../lib/sec_filings.dart';

Future<void> main() async {
  final environment = Platform.environment;
  final lanDataPolicy = LanDataPolicy.fromEnvironment(environment);
  final port = _readPort(environment['A_TRADER_PORT']);
  final selectedProvider = _readProvider(
    environment['A_TRADER_MARKET_DATA_PROVIDER'],
  );
  final alpacaKeyId = environment['ALPACA_API_KEY_ID'];
  final alpacaSecret = environment['ALPACA_API_SECRET_KEY'];
  final twelveDataKey = environment['TWELVE_DATA_API_KEY'];
  final alpacaTermsConfirmed =
      environment['ALPACA_MARKET_DATA_TERMS_CONFIRMED'] == 'true';
  final twelveDataTermsConfirmed =
      environment['TWELVE_DATA_RESEARCH_TERMS_CONFIRMED'] == 'true';
  final alpacaCredentialsPresent =
      _isPresent(alpacaKeyId) && _isPresent(alpacaSecret);
  final alpacaClient =
      selectedProvider == MarketDataProvider.alpaca &&
          alpacaCredentialsPresent &&
          alpacaTermsConfirmed &&
          lanDataPolicy.permits(MarketDataProvider.alpaca)
      ? AlpacaMarketDataClient(
          apiKeyId: alpacaKeyId!,
          apiSecretKey: alpacaSecret!,
          allowCaching: environment['ALPACA_DATA_CACHING_PERMITTED'] == 'true',
        )
      : null;
  final twelveDataCredentialsPresent = _isPresent(twelveDataKey);
  final twelveDataClient =
      selectedProvider == MarketDataProvider.twelveData &&
          twelveDataCredentialsPresent &&
          twelveDataTermsConfirmed &&
          lanDataPolicy.permits(MarketDataProvider.twelveData)
      ? TwelveDataMarketDataClient(
          apiKey: twelveDataKey!,
          quotaLedger: File('.local/twelve_data_quota.json'),
        )
      : null;
  final MarketDataRepository? marketDataClient = switch (selectedProvider) {
    MarketDataProvider.alpaca => alpacaClient,
    MarketDataProvider.twelveData => twelveDataClient,
    MarketDataProvider.schwab => null,
  };
  final secFilings = SecFilingsClient(
    permitted: environment['A_TRADER_SEC_TERMS_CONFIRMED'] == 'true',
    userAgent: environment['SEC_USER_AGENT'] ?? '',
  );
  final providerStatuses = <String, Object?>{
    'alpaca': {
      'credentialsPresent': alpacaCredentialsPresent,
      'termsConfirmed': alpacaTermsConfirmed,
      'configured': alpacaCredentialsPresent && alpacaTermsConfirmed,
      'enabled': alpacaClient != null,
      'selected': selectedProvider == MarketDataProvider.alpaca,
      'integrationImplemented': true,
      'lanDisplayTermsConfirmed': lanDataPolicy.alpacaDisplayConfirmed,
    },
    'twelveData': {
      'credentialsPresent': twelveDataCredentialsPresent,
      'termsConfirmed': twelveDataTermsConfirmed,
      'configured': twelveDataCredentialsPresent && twelveDataTermsConfirmed,
      'enabled': twelveDataClient != null,
      'selected': selectedProvider == MarketDataProvider.twelveData,
      'integrationImplemented': true,
      'personalResearchOnly': true,
      'lanRightsConfirmed': lanDataPolicy.twelveDataRightsConfirmed,
    },
    'schwab': {
      'credentialsPresent':
          _isPresent(environment['SCHWAB_CLIENT_ID']) &&
          _isPresent(environment['SCHWAB_CLIENT_SECRET']),
      'enabled': false,
      'integrationImplemented': false,
    },
    'alphaVantage': {
      'credentialsPresent': _isPresent(environment['ALPHA_VANTAGE_API_KEY']),
      'enabled': false,
      'integrationImplemented': false,
    },
    'brightData': {
      'credentialsPresent': _isPresent(environment['BRIGHT_DATA_API_TOKEN']),
      'enabled': false,
      'integrationImplemented': false,
    },
    'secEdgar': {
      'credentialsPresent': false,
      'enabled': secFilings.enabled,
      'integrationImplemented': true,
      'requiresApiKey': false,
    },
  };

  final assistantConfiguration = AssistantConfiguration.fromEnvironment(
    environment,
  );
  final modelClient = assistantConfiguration.createModelClient();
  final callBudget = AssistantCallBudget(configuration: assistantConfiguration);
  final indicatorService = DailyIndicatorService(
    marketData: marketDataClient,
    provider: selectedProvider,
  );
  final assistantService = modelClient == null || marketDataClient == null
      ? null
      : AssistantService(
          configuration: assistantConfiguration,
          marketData: marketDataClient,
          modelClient: modelClient,
          marketDataProvider: selectedProvider.name,
          marketDataCoverage: _coverage(selectedProvider),
          callBudget: callBudget,
        );
  final researchModel = assistantConfiguration.createResearchClient();
  final researchService = researchModel == null
      ? null
      : ResearchService(
          configuration: assistantConfiguration,
          modelClient: researchModel,
          callBudget: callBudget,
          tools: ResearchTools(
            marketData: marketDataClient,
            provider: selectedProvider,
            secFilings: secFilings,
            indicatorService: indicatorService,
          ),
        );
  final authenticationEnabled = environment['A_TRADER_AUTH_ENABLED'] == 'true';
  final server = ATraderServer(
    bindAddress: environment['A_TRADER_BIND_ADDRESS'] ?? '127.0.0.1',
    port: port,
    selectedProvider: selectedProvider,
    marketDataClient: marketDataClient,
    providerStatuses: providerStatuses,
    assistantConfiguration: assistantConfiguration,
    assistantService: assistantService,
    researchService: researchService,
    indicatorService: indicatorService,
    allowedOrigin: environment['A_TRADER_ALLOWED_ORIGIN'],
    authenticationEnabled: authenticationEnabled,
    authenticationPassword: environment['A_TRADER_AUTH_PASSWORD'],
    staticRoot: environment['A_TRADER_WEB_ROOT'],
    lanDataPolicy: lanDataPolicy,
    lanOrigins: environment['A_TRADER_LAN_ORIGINS'],
  );
  await server.start();
  stdout.writeln(
    'A-Trader service listening on ${server.uri} '
    '(${selectedProvider.name} market data '
    '${marketDataClient == null ? 'disabled' : 'enabled'}, '
    'assistant ${assistantService == null ? 'disabled' : 'enabled'}).',
  );
  if (!InternetAddress.tryParse(server.bindAddress)!.isLoopback) {
    stderr.writeln(
      'WARNING: LAN HTTP is unencrypted. Use only on a trusted private '
      'network; never expose this service to the public Internet.',
    );
    stderr.writeln(
      'No firewall rule was changed. Keep this process running only while '
      'you intend to share the authenticated web app.',
    );
  }
  if (selectedProvider == MarketDataProvider.twelveData &&
      !twelveDataTermsConfirmed) {
    stdout.writeln(
      'Twelve Data is disabled until its personal research terms are confirmed.',
    );
  } else if (selectedProvider == MarketDataProvider.alpaca &&
      !alpacaTermsConfirmed) {
    stdout.writeln(
      'Provider calls are disabled until Alpaca market-data terms are reviewed.',
    );
  }
  if (!lanDataPolicy.permits(selectedProvider)) {
    stdout.writeln(
      'LAN market-data display is disabled until provider-specific LAN rights '
      'are expressly confirmed. Model-forwarding permission is separate.',
    );
  }
  if (!assistantConfiguration.termsConfirmed) {
    stdout.writeln(
      'Assistant forwarding is disabled until model-processing rights are confirmed.',
    );
  } else if (!assistantConfiguration.enabledGate) {
    stdout.writeln(
      'Assistant is disabled until A_TRADER_ASSISTANT_ENABLED=true.',
    );
  }
  if (server.bindAddress == '127.0.0.1' &&
      (environment['A_TRADER_ALLOWED_ORIGIN'] == null ||
          environment['A_TRADER_ALLOWED_ORIGIN']!.isEmpty)) {
    stdout.writeln(
      'Browser cross-origin requests are disabled until '
      'A_TRADER_ALLOWED_ORIGIN is set.',
    );
  }
}

bool _isPresent(String? value) => value != null && value.trim().isNotEmpty;

MarketDataProvider _readProvider(String? value) {
  final normalized = value?.trim().toLowerCase();
  return switch (normalized) {
    null || '' || 'alpaca' => MarketDataProvider.alpaca,
    'twelvedata' || 'twelve_data' => MarketDataProvider.twelveData,
    _ => throw const FormatException(
      'A_TRADER_MARKET_DATA_PROVIDER must be twelveData or alpaca.',
    ),
  };
}

int _readPort(String? value) {
  if (value == null || value.isEmpty) return 8765;
  final port = int.tryParse(value);
  if (port == null || port < 1024 || port > 65535) {
    throw const FormatException(
      'A_TRADER_PORT must be between 1024 and 65535.',
    );
  }
  return port;
}

String _coverage(MarketDataProvider provider) => switch (provider) {
  MarketDataProvider.alpaca =>
    'Supported US stocks and ETFs only; IEX single-exchange coverage; OTC unavailable.',
  MarketDataProvider.twelveData =>
    'US listed equity realtime is partial (about 5% market volume), not consolidated; daily history has complete US volume after midnight ET on the next trading day; OTC unavailable.',
  MarketDataProvider.schwab => 'Schwab market-data integration is unavailable.',
};
