import 'package:flutter/material.dart';

import 'providers/provider_health.dart';

void main() {
  runApp(const MyApp());
}

enum IdeaStatus { recommended, saved, monitoring, passed }

enum DashboardSection { ideas, saved, history }

class MockIdea {
  const MockIdea({
    required this.ticker,
    required this.company,
    required this.price,
    required this.priceTimestamp,
    required this.entryLow,
    required this.entryHigh,
    required this.stop,
    required this.holdingPeriod,
    required this.risk,
    required this.rank,
    required this.summary,
    required this.evidence,
    required this.indicators,
    required this.risks,
  });

  final String ticker;
  final String company;
  final double price;
  final String priceTimestamp;
  final double entryLow;
  final double entryHigh;
  final double stop;
  final String holdingPeriod;
  final String risk;
  final int rank;
  final String summary;
  final List<String> evidence;
  final List<String> indicators;
  final List<String> risks;
}

class AppSettings {
  const AppSettings({
    this.portfolioValue = 10000,
    this.allocationPercent = 15,
    this.holdingDays = 10,
    this.maxStocks = 3,
    this.favorites = const {'NOVA', 'KITE'},
    this.prompt = defaultPrompt,
    this.backendUrl = 'http://127.0.0.1:8765',
  });

  static const defaultPrompt =
      'Review only the verified evidence provided. Explain both supporting '
      'and opposing facts. Never invent data or claim certainty. If the '
      'evidence is insufficient, recommend no trade.';

  final double portfolioValue;
  final double allocationPercent;
  final int holdingDays;
  final int maxStocks;
  final Set<String> favorites;
  final String prompt;
  final String backendUrl;

  AppSettings copyWith({
    double? portfolioValue,
    double? allocationPercent,
    int? holdingDays,
    int? maxStocks,
    Set<String>? favorites,
    String? prompt,
    String? backendUrl,
  }) {
    return AppSettings(
      portfolioValue: portfolioValue ?? this.portfolioValue,
      allocationPercent: allocationPercent ?? this.allocationPercent,
      holdingDays: holdingDays ?? this.holdingDays,
      maxStocks: maxStocks ?? this.maxStocks,
      favorites: favorites ?? this.favorites,
      prompt: prompt ?? this.prompt,
      backendUrl: backendUrl ?? this.backendUrl,
    );
  }
}

const _mockIdeas = [
  MockIdea(
    ticker: 'NOVA',
    company: 'Nova Circuitry (mock company)',
    price: 2.48,
    priceTimestamp: 'Oct 10, 2026 · 3:00 PM ET',
    entryLow: 2.30,
    entryHigh: 2.42,
    stop: 2.12,
    holdingPeriod: '5–10 trading days',
    risk: 'High',
    rank: 1,
    summary: 'A hypothetical pullback setup with improving volume.',
    evidence: [
      'Mock catalyst: product update reported in a fictional company release.',
      'Mock volume: 1.8× its 20-day average in this sample.',
      'No real filing, news article, or quote is attached.',
    ],
    indicators: [
      'Trend: rising short-term average (mock)',
      'Relative volume: 1.8× (mock)',
      'Volatility: elevated (mock)',
    ],
    risks: [
      'Thinly traded names can move through a stop price.',
      'The example has no verified liquidity or exchange data.',
    ],
  ),
  MockIdea(
    ticker: 'KITE',
    company: 'Kite Harbor Robotics (mock company)',
    price: 1.16,
    priceTimestamp: 'Oct 10, 2026 · 2:45 PM ET',
    entryLow: 1.08,
    entryHigh: 1.13,
    stop: 0.99,
    holdingPeriod: '3–7 trading days',
    risk: 'Very high',
    rank: 2,
    summary: 'A speculative watch candidate; confirmation is missing.',
    evidence: [
      'Mock price action is near a hypothetical support zone.',
      'No verified company catalyst is available in this example.',
    ],
    indicators: [
      'Trend: mixed (mock)',
      'Relative volume: 1.2× (mock)',
      'Spread: unavailable',
    ],
    risks: [
      'No spread or average dollar-volume data is available.',
      'The hypothetical setup may never reach its entry range.',
    ],
  ),
  MockIdea(
    ticker: 'ORBT',
    company: 'Orbit Materials (mock company)',
    price: 4.92,
    priceTimestamp: 'Oct 10, 2026 · 2:30 PM ET',
    entryLow: 4.55,
    entryHigh: 4.76,
    stop: 4.28,
    holdingPeriod: '7–12 trading days',
    risk: 'High',
    rank: 3,
    summary: 'A hypothetical breakout retest that needs more evidence.',
    evidence: [
      'Mock chart pattern only; no real market data is used.',
      'No filing or verified news catalyst is attached.',
    ],
    indicators: [
      'Trend: neutral-to-positive (mock)',
      'Relative volume: 1.4× (mock)',
      'Price range: 4.28–5.15 (mock)',
    ],
    risks: [
      'A breakout can fail quickly in low-liquidity securities.',
      'Corporate-action history has not been checked.',
    ],
  ),
];

class MyApp extends StatefulWidget {
  const MyApp({this.providerHealthService, super.key});

  final ProviderHealthService? providerHealthService;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  ThemeMode _themeMode = ThemeMode.system;
  AppSettings _settings = const AppSettings();
  late final ProviderHealthService _providerHealthService;
  late final bool _ownsProviderHealthService;
  final Map<String, IdeaStatus> _statuses = {
    'NOVA': IdeaStatus.recommended,
    'KITE': IdeaStatus.recommended,
    'ORBT': IdeaStatus.recommended,
  };

  @override
  void initState() {
    super.initState();
    _ownsProviderHealthService = widget.providerHealthService == null;
    _providerHealthService =
        widget.providerHealthService ?? ProviderHealthService();
  }

  @override
  void dispose() {
    if (_ownsProviderHealthService) _providerHealthService.close();
    super.dispose();
  }

  void _changeStatus(String ticker, IdeaStatus status) {
    setState(() => _statuses[ticker] = status);
  }

  void _openSettings(BuildContext context) {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => SettingsScreen(
          initialSettings: _settings,
          initialThemeMode: _themeMode,
          providerHealthService: _providerHealthService,
          onSave: (settings, themeMode) {
            setState(() {
              _settings = settings;
              _themeMode = themeMode;
            });
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'A-Trader',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF9CCCF0),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF5FAFF),
        cardTheme: const CardThemeData(elevation: 0, margin: EdgeInsets.zero),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF9CCCF0),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        cardTheme: const CardThemeData(elevation: 0, margin: EdgeInsets.zero),
      ),
      home: DashboardScreen(
        settings: _settings,
        statuses: _statuses,
        onSettings: _openSettings,
        onStatusChanged: _changeStatus,
      ),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({
    required this.settings,
    required this.statuses,
    required this.onSettings,
    required this.onStatusChanged,
    super.key,
  });

  final AppSettings settings;
  final Map<String, IdeaStatus> statuses;
  final ValueChanged<BuildContext> onSettings;
  final void Function(String ticker, IdeaStatus status) onStatusChanged;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  DashboardSection _section = DashboardSection.ideas;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visibleIdeas = _section == DashboardSection.saved
        ? _mockIdeas
              .where(
                (idea) =>
                    widget.statuses[idea.ticker] == IdeaStatus.saved ||
                    widget.statuses[idea.ticker] == IdeaStatus.monitoring,
              )
              .toList()
        : _mockIdeas;

    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final contentWidth = constraints.maxWidth > 1180
                ? 1180.0
                : constraints.maxWidth;
            return Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: contentWidth,
                child: CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                        child: Row(
                          children: [
                            Container(
                              width: 42,
                              height: 42,
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primaryContainer,
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Icon(
                                Icons.show_chart_rounded,
                                color: theme.colorScheme.onPrimaryContainer,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              'A-Trader',
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const Spacer(),
                            IconButton(
                              key: const Key('settings_button'),
                              tooltip: 'Settings',
                              onPressed: () => widget.onSettings(context),
                              icon: const Icon(Icons.settings_outlined),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                        child: _MockDataBanner(),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: _SectionPicker(
                          section: _section,
                          savedCount: widget.statuses.values
                              .where(
                                (status) =>
                                    status == IdeaStatus.saved ||
                                    status == IdeaStatus.monitoring,
                              )
                              .length,
                          onChanged: (section) =>
                              setState(() => _section = section),
                        ),
                      ),
                    ),
                    if (_section == DashboardSection.history)
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(20, 16, 20, 36),
                          child: _MockHistory(),
                        ),
                      )
                    else if (visibleIdeas.isEmpty)
                      const SliverFillRemaining(
                        hasScrollBody: false,
                        child: Center(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                              'No saved ideas yet. Save a mock idea to review it here.',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                        sliver: SliverLayoutBuilder(
                          builder: (context, sliverConstraints) {
                            final width =
                                sliverConstraints.crossAxisExtent > 760
                                ? (sliverConstraints.crossAxisExtent - 16) / 2
                                : sliverConstraints.crossAxisExtent;
                            return SliverToBoxAdapter(
                              child: Wrap(
                                spacing: 16,
                                runSpacing: 16,
                                children: [
                                  for (final idea in visibleIdeas)
                                    SizedBox(
                                      width: width,
                                      child: _IdeaCard(
                                        idea: idea,
                                        status: widget.statuses[idea.ticker]!,
                                        onStatusChanged: (status) =>
                                            widget.onStatusChanged(
                                              idea.ticker,
                                              status,
                                            ),
                                      ),
                                    ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _MockDataBanner extends StatelessWidget {
  const _MockDataBanner();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.tertiaryContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.science_outlined, color: colors.onTertiaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'MOCK DATA — NOT LIVE MARKET INFORMATION',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: colors.onTertiaryContainer,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'All prices, companies, evidence, and outcomes below are illustrative. No provider is connected.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onTertiaryContainer,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionPicker extends StatelessWidget {
  const _SectionPicker({
    required this.section,
    required this.savedCount,
    required this.onChanged,
  });

  final DashboardSection section;
  final int savedCount;
  final ValueChanged<DashboardSection> onChanged;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SegmentedButton<DashboardSection>(
        showSelectedIcon: false,
        segments: [
          const ButtonSegment(
            value: DashboardSection.ideas,
            label: Text('Ideas'),
            icon: Icon(Icons.trending_up),
          ),
          ButtonSegment(
            value: DashboardSection.saved,
            label: Text('Saved ($savedCount)'),
            icon: const Icon(Icons.bookmark_outline),
          ),
          const ButtonSegment(
            value: DashboardSection.history,
            label: Text('History'),
            icon: Icon(Icons.history),
          ),
        ],
        selected: {section},
        onSelectionChanged: (selection) => onChanged(selection.first),
      ),
    );
  }
}

class _IdeaCard extends StatelessWidget {
  const _IdeaCard({
    required this.idea,
    required this.status,
    required this.onStatusChanged,
  });

  final MockIdea idea;
  final IdeaStatus status;
  final ValueChanged<IdeaStatus> onStatusChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSaved =
        status == IdeaStatus.saved || status == IdeaStatus.monitoring;
    return Card(
      clipBehavior: Clip.antiAlias,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 14, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 46,
                  height: 46,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(
                    idea.ticker.substring(0, 1),
                    style: TextStyle(
                      color: theme.colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.w800,
                      fontSize: 19,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        children: [
                          Text(
                            '${idea.rank}. ${idea.ticker}',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          _Tag(label: 'MOCK'),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        idea.company,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: Key('save_${idea.ticker}'),
                  tooltip: isSaved ? 'Remove saved idea' : 'Save idea',
                  onPressed: () => onStatusChanged(
                    isSaved ? IdeaStatus.recommended : IdeaStatus.saved,
                  ),
                  icon: Icon(
                    isSaved ? Icons.bookmark : Icons.bookmark_border,
                    color: isSaved ? theme.colorScheme.primary : null,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Text(idea.summary, style: theme.textTheme.bodyMedium),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
            child: Column(
              children: [
                _SummaryRow(
                  label: 'Last-known price',
                  value: '\$${idea.price.toStringAsFixed(2)} · MOCK',
                ),
                _SummaryRow(
                  label: 'Price timestamp',
                  value: idea.priceTimestamp,
                ),
                _SummaryRow(
                  label: 'Proposed entry',
                  value:
                      '\$${idea.entryLow.toStringAsFixed(2)}–\$${idea.entryHigh.toStringAsFixed(2)}',
                ),
                _SummaryRow(
                  label: 'Stop-loss',
                  value: '\$${idea.stop.toStringAsFixed(2)}',
                ),
                _SummaryRow(label: 'Holding period', value: idea.holdingPeriod),
                _SummaryRow(label: 'Risk', value: idea.risk, last: true),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
            child: ExpansionTile(
              key: Key('details_${idea.ticker}'),
              tilePadding: const EdgeInsets.symmetric(horizontal: 8),
              childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
              title: const Text('Details, evidence & risks'),
              subtitle: const Text('Illustrative indicators only'),
              children: [
                _DetailGroup(
                  title: 'Supporting evidence',
                  items: idea.evidence,
                ),
                _DetailGroup(title: 'Indicators', items: idea.indicators),
                _DetailGroup(title: 'Risks', items: idea.risks),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: Key('why_${idea.ticker}'),
                onPressed: () => _showMockExplanation(context, idea),
                icon: const Icon(Icons.auto_awesome_outlined),
                label: const Text('Ask GPT Why (mock)'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

void _showMockExplanation(BuildContext context, MockIdea idea) {
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('${idea.ticker}: mock explanation'),
      content: const Text(
        'This is a sample response only. No GPT request was made. '
        'The hypothetical setup has limited illustrative support and '
        'substantial microcap liquidity risk; verify all inputs before '
        'considering any real trade.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.label,
    required this.value,
    this.last = false,
  });

  final String label;
  final String value;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 7),
      decoration: BoxDecoration(
        border: last
            ? null
            : Border(
                bottom: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailGroup extends StatelessWidget {
  const _DetailGroup({required this.title, required this.items});

  final String title;
  final List<String> items;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          for (final item in items)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('•  '),
                  Expanded(child: Text(item)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: colors.secondaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: colors.onSecondaryContainer,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _MockHistory extends StatelessWidget {
  const _MockHistory();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Historical results',
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 5),
        Text(
          'Illustrative examples only — not tracked or verified outcomes.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        for (final item in const [
          ('MOCK-01', 'LUMA', 'Completed · hypothetical +4.2%'),
          ('MOCK-02', 'PICO', 'Unfilled · entry range not reached'),
        ])
          Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: ListTile(
              leading: const Icon(Icons.history),
              title: Text('${item.$2} · ${item.$1}'),
              subtitle: Text(item.$3),
              trailing: const _Tag(label: 'MOCK'),
            ),
          ),
      ],
    );
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    required this.initialSettings,
    required this.initialThemeMode,
    required this.onSave,
    required this.providerHealthService,
    super.key,
  });

  final AppSettings initialSettings;
  final ThemeMode initialThemeMode;
  final void Function(AppSettings settings, ThemeMode themeMode) onSave;
  final ProviderHealthService providerHealthService;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _portfolioController;
  late final TextEditingController _allocationController;
  late final TextEditingController _holdingDaysController;
  late final TextEditingController _maxStocksController;
  late final TextEditingController _promptController;
  late final TextEditingController _backendUrlController;
  ProviderHealthSnapshot? _providerHealth;
  String? _providerHealthError;
  bool _checkingProviders = false;
  late double _portfolioValue;
  late double _allocationPercent;
  late int _holdingDays;
  late int _maxStocks;
  late Set<String> _favorites;
  late ThemeMode _themeMode;

  @override
  void initState() {
    super.initState();
    final settings = widget.initialSettings;
    _portfolioValue = settings.portfolioValue;
    _allocationPercent = settings.allocationPercent;
    _holdingDays = settings.holdingDays;
    _maxStocks = settings.maxStocks;
    _favorites = {...settings.favorites};
    _themeMode = widget.initialThemeMode;
    _portfolioController = TextEditingController(
      text: _portfolioValue.toStringAsFixed(0),
    );
    _allocationController = TextEditingController(
      text: _allocationPercent.toStringAsFixed(0),
    );
    _holdingDaysController = TextEditingController(text: '$_holdingDays');
    _maxStocksController = TextEditingController(text: '$_maxStocks');
    _promptController = TextEditingController(text: settings.prompt);
    _backendUrlController = TextEditingController(text: settings.backendUrl);
  }

  @override
  void dispose() {
    _portfolioController.dispose();
    _allocationController.dispose();
    _holdingDaysController.dispose();
    _maxStocksController.dispose();
    _promptController.dispose();
    _backendUrlController.dispose();
    super.dispose();
  }

  void _save() {
    final portfolio = double.tryParse(_portfolioController.text);
    final allocation = double.tryParse(_allocationController.text);
    final days = int.tryParse(_holdingDaysController.text);
    final stocks = int.tryParse(_maxStocksController.text);
    if (portfolio == null ||
        portfolio <= 0 ||
        allocation == null ||
        allocation <= 0 ||
        allocation > 100 ||
        days == null ||
        days <= 0 ||
        stocks == null ||
        stocks <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Enter a positive portfolio, 1–100% allocation, and positive limits.',
          ),
        ),
      );
      return;
    }
    widget.onSave(
      AppSettings(
        portfolioValue: portfolio,
        allocationPercent: allocation,
        holdingDays: days,
        maxStocks: stocks,
        favorites: _favorites,
        backendUrl: _backendUrlController.text.trim(),
        prompt: _promptController.text.trim().isEmpty
            ? AppSettings.defaultPrompt
            : _promptController.text.trim(),
      ),
      _themeMode,
    );
    Navigator.of(context).pop();
  }

  Future<void> _checkProviderConnections() async {
    setState(() {
      _checkingProviders = true;
      _providerHealthError = null;
    });
    try {
      final backendUri = Uri.parse(_backendUrlController.text.trim());
      final snapshot = await widget.providerHealthService.check(backendUri);
      if (!mounted) return;
      setState(() => _providerHealth = snapshot);
    } on FormatException {
      if (!mounted) return;
      setState(() {
        _providerHealth = null;
        _providerHealthError = 'Enter a valid local service URL.';
      });
    } on ProviderHealthException catch (error) {
      if (!mounted) return;
      setState(() {
        _providerHealth = null;
        _providerHealthError = error.message;
      });
    } finally {
      if (mounted) setState(() => _checkingProviders = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          TextButton(
            key: const Key('save_settings'),
            onPressed: _save,
            child: const Text('Save'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
            child: ListView(
              key: const Key('settings_list'),
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              children: [
                Text(
                  'Risk & portfolio',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final columns = constraints.maxWidth > 560 ? 2 : 1;
                    final fieldWidth =
                        (constraints.maxWidth - (columns - 1) * 12) / columns;
                    return Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        SizedBox(
                          width: fieldWidth,
                          child: _NumberField(
                            key: const Key('portfolio_value'),
                            controller: _portfolioController,
                            label: 'Portfolio value (\$)',
                            decimal: true,
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                        SizedBox(
                          width: fieldWidth,
                          child: _NumberField(
                            key: const Key('allocation_percent'),
                            controller: _allocationController,
                            label: 'Allocation available (%)',
                            decimal: true,
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                        SizedBox(
                          width: fieldWidth,
                          child: _NumberField(
                            key: const Key('holding_days'),
                            controller: _holdingDaysController,
                            label: 'Holding period (calendar days)',
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                        SizedBox(
                          width: fieldWidth,
                          child: _NumberField(
                            key: const Key('max_stocks'),
                            controller: _maxStocksController,
                            label: 'Maximum number of ideas',
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 24),
                Text(
                  'Favorites',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Mock favorites receive extra attention, but cannot bypass risk checks.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final ticker in ['NOVA', 'KITE', 'ORBT'])
                      FilterChip(
                        key: Key('favorite_$ticker'),
                        label: Text(ticker),
                        selected: _favorites.contains(ticker),
                        onSelected: (selected) {
                          setState(() {
                            if (selected) {
                              _favorites.add(ticker);
                            } else {
                              _favorites.remove(ticker);
                            }
                          });
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 24),
                Text(
                  'Appearance',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment(
                        value: ThemeMode.system,
                        label: Text('System'),
                        icon: Icon(Icons.settings_suggest_outlined),
                      ),
                      ButtonSegment(
                        value: ThemeMode.light,
                        label: Text('Light'),
                        icon: Icon(Icons.light_mode_outlined),
                      ),
                      ButtonSegment(
                        value: ThemeMode.dark,
                        label: Text('Dark'),
                        icon: Icon(Icons.dark_mode_outlined),
                      ),
                    ],
                    selected: {_themeMode},
                    onSelectionChanged: (selection) =>
                        setState(() => _themeMode = selection.first),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'GPT prompt · version 1 (mock)',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const Key('prompt_editor'),
                  controller: _promptController,
                  minLines: 4,
                  maxLines: 8,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    helperText:
                        'Editable preview only. No model request is sent.',
                    alignLabelWithHint: true,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                _PromptPreview(
                  prompt: _promptController.text,
                  portfolioValue: _portfolioController.text,
                  allocationPercent: _allocationController.text,
                  holdingDays: _holdingDaysController.text,
                  maxStocks: _maxStocksController.text,
                  favorites: _favorites,
                ),
                const SizedBox(height: 24),
                Text(
                  'Research & data providers',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Provider keys stay in the local service environment; never paste them into Flutter settings.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('backend_url'),
                  controller: _backendUrlController,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'Local service URL',
                    border: OutlineInputBorder(),
                    helperText:
                        'Loopback only. Restart the service after changing server environment settings.',
                  ),
                  onChanged: (_) => setState(() {
                    _providerHealth = null;
                    _providerHealthError = null;
                  }),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    key: const Key('check_provider_connections'),
                    onPressed: _checkingProviders
                        ? null
                        : _checkProviderConnections,
                    icon: _checkingProviders
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.sync),
                    label: Text(
                      _checkingProviders
                          ? 'Checking local service…'
                          : 'Check local connections',
                    ),
                  ),
                ),
                if (_providerHealthError != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _providerHealthError!,
                    key: const Key('provider_health_error'),
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ],
                const SizedBox(height: 8),
                _ProviderStatus(
                  name: 'Schwab Trader API',
                  status: _providerLabel(
                    _providerHealth?.providers['schwab'],
                    credentialsVariable:
                        'SCHWAB_CLIENT_ID / '
                        'SCHWAB_CLIENT_SECRET',
                    pendingStatus: 'Approval / adapter pending',
                  ),
                  details:
                      'Credentials are only staged when Schwab approves the app and read-only market-data access. OAuth adapter is not implemented.',
                ),
                _ProviderStatus(
                  name: 'Alpaca IEX market data',
                  status: _providerLabel(
                    _providerHealth?.providers['alpaca'],
                    credentialsVariable:
                        'ALPACA_API_KEY_ID / '
                        'ALPACA_API_SECRET_KEY',
                    readyStatus: 'Configured · IEX only; provider not tested',
                    pendingStatus: 'Terms confirmation required',
                  ),
                  details:
                      'Free Basic IEX only; no OTC coverage or paid fallback. Data-use terms must be confirmed before requests are enabled.',
                ),
                _ProviderStatus(
                  name: 'Alpha Vantage daily data',
                  status: _providerLabel(
                    _providerHealth?.providers['alphaVantage'],
                    credentialsVariable: 'ALPHA_VANTAGE_API_KEY',
                  ),
                  details:
                      'Credentials can be staged for later setup. Connector is not implemented; premium intraday data is excluded.',
                ),
                _ProviderStatus(
                  name: 'SEC EDGAR filings',
                  status: _providerLabel(
                    _providerHealth?.providers['secEdgar'],
                    noKeyRequired: true,
                  ),
                  details:
                      'Public EDGAR APIs require no API key. SEC integration is not implemented yet.',
                ),
                _ProviderStatus(
                  name: 'Bright Data Social Scraper (X / Reddit)',
                  status: _providerLabel(
                    _providerHealth?.providers['brightData'],
                    credentialsVariable: 'BRIGHT_DATA_API_TOKEN',
                    pendingStatus: 'Permission / adapter pending',
                  ),
                  details:
                      'Keep disabled unless both Bright Data terms and platform rules authorize collection and model processing.',
                ),
                _ProviderStatus(
                  name: 'OpenAI',
                  status: _providerLabel(
                    _providerHealth?.providers['openAi'],
                    credentialsVariable: 'OPENAI_API_KEY',
                  ),
                  details:
                      'OpenAI connector is not implemented. Requests are not made and credentials are not needed for this phase.',
                ),
                if (_providerHealth != null)
                  Text(
                    'Local service reachable. “Credentials detected” does not mean a provider connection or entitlement was tested.',
                    key: const Key('provider_health_success'),
                    style: theme.textTheme.bodySmall,
                  ),
                const SizedBox(height: 16),
                Text(
                  'All changes are local to this demo session and reset when the app restarts.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.controller,
    required this.label,
    this.onChanged,
    this.decimal = false,
    super.key,
  });

  final TextEditingController controller;
  final String label;
  final ValueChanged<String>? onChanged;
  final bool decimal;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      keyboardType: TextInputType.numberWithOptions(decimal: decimal),
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        labelText: label,
      ),
    );
  }
}

class _PromptPreview extends StatelessWidget {
  const _PromptPreview({
    required this.prompt,
    required this.portfolioValue,
    required this.allocationPercent,
    required this.holdingDays,
    required this.maxStocks,
    required this.favorites,
  });

  final String prompt;
  final String portfolioValue;
  final String allocationPercent;
  final String holdingDays;
  final String maxStocks;
  final Set<String> favorites;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = [
      'SYSTEM PROMPT (editable, version 1)',
      prompt,
      '',
      'MARKET / TECHNICAL INPUTS',
      'NOVA: mock price \$2.48; entry \$2.30–\$2.42; stop \$2.12; mock relative volume 1.8×.',
      '',
      'RESEARCH EVIDENCE',
      'Mock-only sample. No live articles or filings are provided.',
      '',
      'PORTFOLIO / RISK',
      'Portfolio: \$$portfolioValue; allocation: $allocationPercent%; '
          'horizon: $holdingDays days; max ideas: $maxStocks; '
          'favorites: ${favorites.isEmpty ? 'none' : favorites.join(', ')}.',
      '',
      'Model: none · prompt version: mock-v1 · credentials: not included.',
    ].join('\n');

    return Container(
      key: const Key('prompt_preview'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Request preview · mock inputs only',
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          SelectableText(
            preview,
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

String _providerLabel(
  ProviderConnectionStatus? status, {
  String? credentialsVariable,
  String? readyStatus,
  String? pendingStatus,
  bool noKeyRequired = false,
}) {
  if (status == null) {
    if (noKeyRequired) return 'Not checked · no key required';
    return 'Not checked · needs ${credentialsVariable ?? 'configuration'}';
  }
  if (noKeyRequired && !status.integrationImplemented) {
    return 'No key required · integration pending';
  }
  if (!status.credentialsPresent) {
    return 'Credentials missing · ${credentialsVariable ?? 'not configured'}';
  }
  if (status.enabled && status.integrationImplemented) {
    return readyStatus ?? 'Configured · provider not tested';
  }
  return 'Credentials detected · ${pendingStatus ?? 'connector pending'}';
}

class _ProviderStatus extends StatelessWidget {
  const _ProviderStatus({
    required this.name,
    required this.status,
    required this.details,
  });

  final String name;
  final String status;
  final String details;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 7),
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.key_outlined),
        title: Text(name),
        subtitle: Text('$status\n$details'),
        isThreeLine: true,
      ),
    );
  }
}
