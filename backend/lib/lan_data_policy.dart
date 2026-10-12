import 'package:a_trade/market_data/market_data.dart';

class LanDataPolicy {
  const LanDataPolicy({
    required this.lanMode,
    this.alpacaDisplayConfirmed = false,
    this.twelveDataRightsConfirmed = false,
  });

  factory LanDataPolicy.fromEnvironment(Map<String, String> environment) =>
      LanDataPolicy(
        lanMode:
            environment['A_TRADER_AUTH_ENABLED'] == 'true' ||
            !const {
              '127.0.0.1',
              '::1',
            }.contains(environment['A_TRADER_BIND_ADDRESS'] ?? '127.0.0.1'),
        alpacaDisplayConfirmed:
            environment['ALPACA_LAN_DISPLAY_TERMS_CONFIRMED'] == 'true',
        twelveDataRightsConfirmed:
            environment['TWELVE_DATA_LAN_RIGHTS_CONFIRMED'] == 'true',
      );

  final bool lanMode;
  final bool alpacaDisplayConfirmed;
  final bool twelveDataRightsConfirmed;

  bool permits(MarketDataProvider provider) =>
      !lanMode ||
      switch (provider) {
        MarketDataProvider.alpaca => alpacaDisplayConfirmed,
        MarketDataProvider.twelveData => twelveDataRightsConfirmed,
        MarketDataProvider.schwab => false,
      };
}
