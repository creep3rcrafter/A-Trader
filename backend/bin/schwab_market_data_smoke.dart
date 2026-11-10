import 'dart:io';

import 'package:a_trade/market_data/alpaca_market_data_client.dart';

// ignore: avoid_relative_lib_imports
import '../lib/lan_data_policy.dart';
// ignore: avoid_relative_lib_imports
import '../lib/schwab_market_data.dart';
// ignore: avoid_relative_lib_imports
import '../lib/schwab_oauth.dart';
import 'package:a_trade/market_data/market_data.dart';

Future<void> main(List<String> arguments) async {
  SchwabMarketDataClient? client;
  SchwabOAuthClient? oauth;
  try {
    final env = Platform.environment;
    if (!Platform.isWindows ||
        env['A_TRADER_MARKET_DATA_PROVIDER'] != 'schwab' ||
        env['SCHWAB_MARKET_DATA_TERMS_CONFIRMED'] != 'true' ||
        !LanDataPolicy.fromEnvironment(
          env,
        ).permits(MarketDataProvider.schwab) ||
        arguments.length != 1 ||
        !RegExp(r'^[A-Z0-9.-]{1,15}$').hasMatch(arguments.single)) {
      throw const FormatException(
        'Explicit Schwab selection and usage rights required.',
      );
    }
    final root = File.fromUri(Platform.script).parent.parent.parent.path;
    oauth = SchwabOAuthClient(
      clientId: env['SCHWAB_CLIENT_ID'] ?? '',
      clientSecret: env['SCHWAB_CLIENT_SECRET'] ?? '',
      store: WindowsSchwabTokenStore('$root\\scripts\\schwab_token_store.ps1'),
      lockPath: '$root\\.local\\schwab\\oauth.lock',
    );
    client = SchwabMarketDataClient(oauth: oauth);
    final quote = await client.latestQuote(arguments.single);
    if (quote == null) throw const MarketDataException('No quote available.');
    final now = DateTime.now().toUtc();
    final end = DateTime.utc(now.year, now.month, now.day);
    final bars = await client.dailyBars(
      arguments.single,
      start: end.subtract(const Duration(days: 30)),
      end: end,
    );
    stdout.writeln(
      'Schwab read-only smoke: ${quote.symbol}; one quote + one 30-day history request; no retries.',
    );
    stdout.writeln(
      'Source: ${quote.sourceTimestamp.toIso8601String()}; retrieved: ${quote.retrievedAt.toIso8601String()}; realtime=${quote.realtime ?? 'unknown'}; quoteType=${quote.quoteType ?? 'unknown'}.',
    );
    stdout.writeln(
      'Daily bars: ${bars.length}; adjustment=unknown; indicators unavailable.',
    );
    stdout.writeln(schwabCoverage);
  } on MarketDataException catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
  } on SchwabAuthException catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
  } on FormatException {
    stderr.writeln(
      'Explicit provider selection/permissions and normalized equity ticker required.',
    );
    exitCode = 1;
  } finally {
    client?.close();
    oauth?.close();
  }
}
