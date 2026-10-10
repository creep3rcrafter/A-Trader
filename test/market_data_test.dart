import 'package:flutter_test/flutter_test.dart';

import 'package:a_trade/market_data/market_data.dart';

void main() {
  group('AlpacaMarketDataNormalizer', () {
    const retrievedAt = '2026-10-09T20:00:01Z';

    test(
      'normalizes a latest trade and quote into a timestamped IEX quote',
      () {
        final trade = AlpacaMarketDataNormalizer.latestTrade(
          symbol: ' aapl ',
          response: {
            'symbol': 'AAPL',
            'trade': {'p': 171.29, 't': '2026-10-09T20:00:00Z'},
          },
          retrievedAt: DateTime.parse(retrievedAt),
        );
        final quote = AlpacaMarketDataNormalizer.latestQuote(
          symbol: 'AAPL',
          response: {
            'quotes': {
              'AAPL': {'bp': 171.20, 'ap': 171.30, 't': '2026-10-09T19:59:59Z'},
            },
          },
          retrievedAt: DateTime.parse(retrievedAt),
        );

        final combined = trade!.merge(quote!);

        expect(combined.symbol, 'AAPL');
        expect(combined.provider, MarketDataProvider.alpaca);
        expect(combined.feed, MarketDataFeed.iex);
        expect(combined.lastPrice, 171.29);
        expect(combined.bidPrice, 171.20);
        expect(combined.askPrice, 171.30);
        expect(
          combined.sourceTimestamp,
          DateTime.parse('2026-10-09T20:00:00Z'),
        );
      },
    );

    test('normalizes daily OHLCV bars and records raw adjustment', () {
      final bars = AlpacaMarketDataNormalizer.dailyBars(
        symbol: 'AAPL',
        response: {
          'symbol': 'AAPL',
          'bars': [
            {
              't': '2026-10-09T04:00:00Z',
              'o': 172.02,
              'h': 173.07,
              'l': 170.341,
              'c': 171.21,
              'v': 51861083,
              'n': 535134,
              'vw': 171.599691,
            },
          ],
        },
        retrievedAt: DateTime.parse(retrievedAt),
      );

      expect(bars, hasLength(1));
      expect(bars.single.provider, MarketDataProvider.alpaca);
      expect(bars.single.feed, MarketDataFeed.iex);
      expect(bars.single.open, 172.02);
      expect(bars.single.low, 170.341);
      expect(bars.single.volume, 51861083);
      expect(bars.single.tradeCount, 535134);
      expect(bars.single.volumeWeightedPrice, 171.599691);
      expect(bars.single.adjustment, PriceAdjustment.raw);
    });

    test('returns no quote when the requested symbol is missing', () {
      expect(
        AlpacaMarketDataNormalizer.latestTrade(
          symbol: 'AAPL',
          response: {'trades': <String, Object>{}},
          retrievedAt: DateTime.parse(retrievedAt),
        ),
        isNull,
      );
    });

    test('rejects mismatched symbols, malformed and impossible bars', () {
      expect(
        () => AlpacaMarketDataNormalizer.dailyBars(
          symbol: 'AAPL',
          response: {'symbol': 'MSFT', 'bars': <Object>[]},
          retrievedAt: DateTime.parse(retrievedAt),
        ),
        throwsFormatException,
      );
      expect(
        () => AlpacaMarketDataNormalizer.dailyBars(
          symbol: 'AAPL',
          response: {
            'bars': [
              {
                't': '2026-10-09T04:00:00Z',
                'o': 172,
                'h': 170,
                'l': 171,
                'c': 171,
                'v': 100,
              },
            ],
          },
          retrievedAt: DateTime.parse(retrievedAt),
        ),
        throwsFormatException,
      );
    });
  });

  group('MarketQuote freshness', () {
    final timestamp = DateTime.parse('2026-10-09T20:00:00Z');

    MarketQuote quote(MarketDataFeed feed) => MarketQuote(
      symbol: 'AAPL',
      provider: MarketDataProvider.alpaca,
      feed: feed,
      retrievedAt: timestamp,
      lastPrice: 171.29,
      lastTradeAt: timestamp,
    );

    test('distinguishes fresh, stale, delayed, and future timestamps', () {
      expect(
        quote(MarketDataFeed.iex).freshnessAt(
          now: timestamp.add(const Duration(seconds: 10)),
          maximumAge: const Duration(minutes: 1),
        ),
        MarketDataFreshness.fresh,
      );
      expect(
        quote(MarketDataFeed.iex).freshnessAt(
          now: timestamp.add(const Duration(minutes: 2)),
          maximumAge: const Duration(minutes: 1),
        ),
        MarketDataFreshness.stale,
      );
      expect(
        quote(MarketDataFeed.delayedSip).freshnessAt(
          now: timestamp.add(const Duration(seconds: 10)),
          maximumAge: const Duration(minutes: 1),
        ),
        MarketDataFreshness.delayed,
      );
      expect(
        quote(MarketDataFeed.iex).freshnessAt(
          now: timestamp.subtract(const Duration(seconds: 1)),
          maximumAge: const Duration(minutes: 1),
        ),
        MarketDataFreshness.unavailable,
      );
    });
  });
}
