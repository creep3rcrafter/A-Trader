import 'dart:async';

import 'package:flutter/material.dart';

import 'market_data/local_market_data_service.dart';
import 'market_data/live_ideas_view.dart';
import 'providers/local_service_url.dart';
import 'providers/provider_health.dart';
import 'providers/assistant_service.dart';
import 'providers/backend_process.dart';

void main() {
  runApp(const MyApp());
}

enum IdeaStatus { recommended, saved, monitoring, passed }

enum DashboardSection { ideas, saved, history }

class AppSettings {
  const AppSettings({
    this.portfolioValue = 10000,
    this.allocationPercent = 15,
    this.holdingDays = 10,
    this.maxStocks = 3,
    this.favorites = const {},
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

class MyApp extends StatefulWidget {
  const MyApp({
    this.providerHealthService,
    this.marketDataService,
    this.assistantService,
    this.backendProcessController,
    super.key,
  });

  final ProviderHealthService? providerHealthService;
  final LocalMarketDataService? marketDataService;
  final AssistantService? assistantService;
  final BackendProcessController? backendProcessController;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  ThemeMode _themeMode = ThemeMode.system;
  AppSettings _settings = const AppSettings();
  late final ProviderHealthService _providerHealthService;
  late final bool _ownsProviderHealthService;
  late final LocalMarketDataService _marketDataService;
  late final bool _ownsMarketDataService;
  late final AssistantService _assistantService;
  late final bool _ownsAssistantService;
  late final BackendProcessController _backendProcessController;
  late final bool _ownsBackendProcessController;
  final Map<String, IdeaStatus> _statuses = {};

  @override
  void initState() {
    super.initState();
    _settings = AppSettings(backendUrl: defaultServiceUrl());
    _ownsProviderHealthService = widget.providerHealthService == null;
    _providerHealthService =
        widget.providerHealthService ?? ProviderHealthService();
    _ownsMarketDataService = widget.marketDataService == null;
    _marketDataService = widget.marketDataService ?? LocalMarketDataService();
    _ownsAssistantService = widget.assistantService == null;
    _assistantService = widget.assistantService ?? AssistantService();
    _ownsBackendProcessController = widget.backendProcessController == null;
    _backendProcessController =
        widget.backendProcessController ?? createBackendProcessController();
  }

  @override
  void dispose() {
    if (_ownsProviderHealthService) _providerHealthService.close();
    if (_ownsMarketDataService) _marketDataService.close();
    if (_ownsAssistantService) _assistantService.close();
    if (_ownsBackendProcessController) _backendProcessController.dispose();
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
          backendProcessController: _backendProcessController,
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
        marketDataService: _marketDataService,
        assistantService: _assistantService,
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
    required this.marketDataService,
    required this.assistantService,
    super.key,
  });

  final AppSettings settings;
  final Map<String, IdeaStatus> statuses;
  final ValueChanged<BuildContext> onSettings;
  final void Function(String ticker, IdeaStatus status) onStatusChanged;
  final LocalMarketDataService marketDataService;
  final AssistantService assistantService;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  DashboardSection _section = DashboardSection.ideas;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 36),
                        child: Column(
                          children: [
                            if (_section == DashboardSection.history)
                              const Text(
                                'No historical results yet. Persistent recommendation '
                                'journaling and outcome tracking are not implemented.',
                              ),
                            Offstage(
                              key: const ValueKey('live_ideas'),
                              offstage: _section == DashboardSection.history,
                              child: LiveIdeasView(
                                backendUrl: widget.settings.backendUrl,
                                service: widget.marketDataService,
                                assistantService: widget.assistantService,
                                analysisPrompt: widget.settings.prompt,
                                holdingDays: widget.settings.holdingDays,
                                savedOnly: _section == DashboardSection.saved,
                                savedTickers: {
                                  for (final entry in widget.statuses.entries)
                                    if (entry.value == IdeaStatus.saved ||
                                        entry.value == IdeaStatus.monitoring)
                                      entry.key,
                                },
                                onToggleSaved: (ticker) =>
                                    widget.onStatusChanged(
                                      ticker,
                                      widget.statuses[ticker] ==
                                                  IdeaStatus.saved ||
                                              widget.statuses[ticker] ==
                                                  IdeaStatus.monitoring
                                          ? IdeaStatus.recommended
                                          : IdeaStatus.saved,
                                    ),
                              ),
                            ),
                          ],
                        ),
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

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    required this.initialSettings,
    required this.initialThemeMode,
    required this.onSave,
    required this.providerHealthService,
    this.backendProcessController,
    super.key,
  });

  final AppSettings initialSettings;
  final ThemeMode initialThemeMode;
  final void Function(AppSettings settings, ThemeMode themeMode) onSave;
  final ProviderHealthService providerHealthService;
  final BackendProcessController? backendProcessController;

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
  bool _healthInFlight = false;
  Timer? _healthTimer;
  bool _controllingBackend = false;
  String? _backendControlMessage;
  int _healthGeneration = 0;
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
    unawaited(_checkProviderConnections());
    _healthTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(_checkProviderConnections()),
    );
  }

  @override
  void dispose() {
    _healthGeneration++;
    _healthTimer?.cancel();
    _portfolioController.dispose();
    _allocationController.dispose();
    _holdingDaysController.dispose();
    _maxStocksController.dispose();
    _promptController.dispose();
    _backendUrlController.dispose();
    super.dispose();
  }

  void _save() {
    final backendUri = Uri.tryParse(_backendUrlController.text.trim());
    if (backendUri == null || !isLocalServiceUri(backendUri)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Use loopback or the same server as this web app.'),
        ),
      );
      return;
    }
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
    if (_healthInFlight || !mounted) return;
    _healthInFlight = true;
    final generation = ++_healthGeneration;
    setState(() {
      _checkingProviders = true;
      _providerHealthError = null;
    });
    try {
      final backendUri = Uri.parse(_backendUrlController.text.trim());
      final snapshot = await widget.providerHealthService.check(backendUri);
      if (!mounted || generation != _healthGeneration) return;
      setState(() => _providerHealth = snapshot);
    } on FormatException {
      if (!mounted || generation != _healthGeneration) return;
      setState(() {
        _providerHealth = null;
        _providerHealthError = 'Enter a valid local service URL.';
      });
    } on ProviderHealthException catch (error) {
      if (!mounted || generation != _healthGeneration) return;
      setState(() {
        _providerHealth = null;
        _providerHealthError = error.message;
      });
    } on Exception {
      if (!mounted || generation != _healthGeneration) return;
      setState(() {
        _providerHealth = null;
        _providerHealthError = 'Could not check the local service.';
      });
    } finally {
      _healthInFlight = false;
      if (mounted && generation == _healthGeneration) {
        setState(() => _checkingProviders = false);
      } else if (mounted) {
        unawaited(_checkProviderConnections());
      }
    }
  }

  void _serviceUrlChanged() {
    setState(() {
      _healthGeneration++;
      _checkingProviders = true;
      _providerHealth = null;
      _providerHealthError = null;
      _backendControlMessage = null;
    });
    unawaited(_checkProviderConnections());
  }

  Future<void> _controlBackend({required bool start}) async {
    final controller = widget.backendProcessController;
    if (controller == null || !controller.available || _controllingBackend) {
      return;
    }
    setState(() {
      _controllingBackend = true;
      _backendControlMessage = null;
    });
    try {
      if (start) {
        final uri = Uri.parse(_backendUrlController.text.trim());
        await _checkProviderConnections();
        if (!mounted) return;
        if (_providerHealth != null) {
          setState(() {
            _backendControlMessage =
                'Existing backend detected. It is not owned by this app and will not be stopped.';
          });
          return;
        }
        await controller.start(uri);
        for (var attempt = 0; attempt < 10 && mounted; attempt++) {
          await Future<void>.delayed(const Duration(seconds: 1));
          if (!mounted) return;
          await _checkProviderConnections();
          if (_providerHealth != null || !controller.ownsBackend) break;
        }
        if (mounted) {
          setState(() {
            _backendControlMessage = !controller.ownsBackend
                ? 'The app-owned backend exited during startup. Check local setup; any other backend is not controlled by this app.'
                : _providerHealth != null
                ? 'Backend started by this app.'
                : 'Backend launched but not reachable yet. Checks continue every 30 seconds; Stop affects only this app’s process.';
          });
        }
      } else {
        _healthGeneration++;
        await controller.stop();
        if (!mounted) return;
        await _checkProviderConnections();
        if (mounted) {
          setState(() => _backendControlMessage = 'App-owned backend stopped.');
        }
      }
    } on BackendProcessException catch (error) {
      if (mounted) setState(() => _backendControlMessage = error.message);
    } on Exception {
      if (mounted) {
        setState(() {
          _backendControlMessage = 'Backend control failed. Check local setup.';
        });
      }
    } finally {
      if (mounted) setState(() => _controllingBackend = false);
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
                  'Favorites are session-only. Automated research and risk screening are not implemented yet.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final ticker in temporaryStocks.map(
                      (stock) => stock.$1,
                    ))
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
                  'Analysis prompt · draft version 1',
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
                        'Used only when you press Ask AI on a stock. Saving does not send a model request.',
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
                        'Loopback or this web app\'s same-origin server only. Save to reload Ideas. Server keys can be stored privately with the setup script.',
                  ),
                  enabled: !_controllingBackend,
                  onChanged: (_) => _serviceUrlChanged(),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Semantics(
                    key: const Key('local_connection_status'),
                    liveRegion: true,
                    label: _checkingProviders
                        ? 'Checking local service'
                        : _providerHealth != null
                        ? 'Local service reachable'
                        : 'Local service unreachable',
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _checkingProviders
                              ? Icons.pending
                              : _providerHealth != null
                              ? Icons.check_circle
                              : Icons.cancel,
                          key: const Key('local_connection_icon'),
                          color: _checkingProviders
                              ? theme.colorScheme.onSurfaceVariant
                              : _providerHealth != null
                              ? Colors.green
                              : Colors.red,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            _checkingProviders
                                ? 'Checking local service…'
                                : _providerHealth != null
                                ? 'Local service reachable'
                                : 'Local service unreachable',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const Text(
                  'Automatic check every 30 seconds while Settings is open.',
                ),
                if (widget.backendProcessController?.available == true) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton.icon(
                        key: const Key('start_backend'),
                        onPressed:
                            _controllingBackend ||
                                _checkingProviders ||
                                _providerHealth != null ||
                                widget.backendProcessController!.ownsBackend
                            ? null
                            : () => _controlBackend(start: true),
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Start backend'),
                      ),
                      OutlinedButton.icon(
                        key: const Key('stop_backend'),
                        onPressed:
                            _controllingBackend ||
                                !widget.backendProcessController!.ownsBackend
                            ? null
                            : () => _controlBackend(start: false),
                        icon: const Icon(Icons.stop),
                        label: const Text('Stop backend'),
                      ),
                    ],
                  ),
                  const Text(
                    'Stop affects only the backend started by this app. An externally started backend is never stopped.',
                  ),
                  if (_backendControlMessage != null)
                    Text(
                      _backendControlMessage!,
                      key: const Key('backend_control_message'),
                    ),
                ],
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
                  name: 'Twelve Data market research',
                  status: _providerLabel(
                    _providerHealth?.providers['twelveData'],
                    credentialsVariable: 'TWELVE_DATA_API_KEY',
                    readyStatus:
                        'Configured for research/testing; provider not tested',
                    pendingStatus: 'Research terms confirmation required',
                  ),
                  details:
                      'Basic free REST: 8 credits/minute, 800/day. Default US feed is partial-volume; OTC and paid add-ons are excluded. Personal research/testing only, not shared display.',
                ),
                _ProviderStatus(
                  name: 'Schwab Trader API',
                  status: _providerLabel(
                    _providerHealth?.providers['schwab'],
                    credentialsVariable:
                        'SCHWAB_CLIENT_ID / '
                        'SCHWAB_CLIENT_SECRET',
                    pendingStatus:
                        'Select Schwab and confirm market-data/display rights privately',
                  ),
                  details:
                      'Read-only equity quotes and bounded daily history via private OAuth. Source realtime/quoteType do not verify SIP entitlement. Adjustment unknown: indicators unavailable. Accounts/orders disabled.',
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
                      'Optional paid analysis, server-side only. Used when configured and explicitly enabled; errors never trigger a silent provider switch.',
                ),
                _ProviderStatus(
                  name: 'LM Studio local AI',
                  status: _providerLabel(
                    _providerHealth?.providers['lmStudio'],
                    noKeyRequired: true,
                    readyStatus: 'Configured locally; model not tested',
                    pendingStatus:
                        'Configure an installed model and enable analysis',
                  ),
                  details:
                      'Local server at 127.0.0.1:1234; no API charges for local inference. Fallback when no OpenAI key is configured. Model and data-use permissions are configured on the server.',
                ),
                if (_providerHealth != null)
                  Text(
                    'Local service reachable. “Credentials detected” does not mean a provider connection or entitlement was tested.',
                    key: const Key('provider_health_success'),
                    style: theme.textTheme.bodySmall,
                  ),
                const SizedBox(height: 16),
                Text(
                  'UI settings reset when the app restarts. Server credentials are saved separately by scripts\\setup_local.ps1 using Windows user-bound encryption.',
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
      'Ask AI fetches a verified quote on the server and includes its source, timestamps and missing-data limitations. No technical screening or trade-price calculations are implemented.',
      '',
      'RESEARCH EVIDENCE',
      'No articles or filings are connected yet.',
      '',
      'PORTFOLIO / RISK',
      'Portfolio: \$$portfolioValue; allocation: $allocationPercent%; '
          'horizon: $holdingDays days; max ideas: $maxStocks; '
          'favorites: ${favorites.isEmpty ? 'none' : favorites.join(', ')}.',
      '',
      'Model: server-selected OpenAI when configured, otherwise local LM Studio; '
          'explicit server enablement and data-use permission required. '
          'Prompt version: draft-v1 · credentials: never included.',
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
            'Draft request preview · requests only through Ask AI',
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
  if (noKeyRequired) {
    return status.enabled
        ? readyStatus ?? 'Configured · provider not tested'
        : pendingStatus ?? 'Not enabled · no key required';
  }
  if (!status.credentialsPresent) {
    return 'Credentials missing · ${credentialsVariable ?? 'not configured'}';
  }
  if (status.enabled && status.integrationImplemented) {
    return readyStatus ?? 'Configured · provider not tested';
  }
  if (status.id == 'schwab' && status.integrationImplemented) {
    if (!status.authorizationStored) {
      return 'Credentials detected · private OAuth required';
    }
    if (!status.termsConfirmed) {
      return 'Private OAuth stored · confirm market-data usage rights';
    }
    if (!status.selected) {
      return 'Private OAuth stored · not selected as active provider';
    }
    return 'Private OAuth stored · check LAN display rights/platform';
  }
  if (status.id == 'twelveData' &&
      status.integrationImplemented &&
      status.termsConfirmed) {
    return 'Credentials detected · not selected as active provider';
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
