part of 'main.dart';

enum _OverviewChart { equity, generations, drawdown }

class _DashboardOverview extends StatefulWidget {
  const _DashboardOverview({
    required this.controller,
    required this.accounts,
    required this.generationEquity,
    required this.colors,
    required this.buildFullMetrics,
    required this.buildReadiness,
  });

  final DashboardController controller;
  final List<Map<String, dynamic>> accounts;
  final List<Map<String, dynamic>> generationEquity;
  final Map<String, Color> colors;
  final WidgetBuilder buildFullMetrics;
  final WidgetBuilder buildReadiness;

  @override
  State<_DashboardOverview> createState() => _DashboardOverviewState();
}

class _DashboardOverviewState extends State<_DashboardOverview> {
  _OverviewChart? _chart;
  bool _showTrials = false;
  bool _dollars = true;

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final status = controller.status;
    final changes = controller.snapshot['variableChanges'];
    final equity = _equityCard(context);
    final metrics = _OverviewMetrics(
      accounts: widget.accounts,
      colors: widget.colors,
    );
    return LayoutBuilder(
      builder: (context, constraints) => ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
        children: [
          _SimulationActivity(status: status, compact: true),
          _SimulationControls(controller: controller),
          const SizedBox(height: 6),
          if (constraints.maxWidth >= 1080)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: equity),
                const SizedBox(width: 8),
                Expanded(child: metrics),
              ],
            )
          else ...[
            equity,
            const SizedBox(height: 6),
            metrics,
          ],
          const SizedBox(height: 6),
          _PositionTally(accounts: widget.accounts),
          PopulationPerformance(controller: controller),
          if (changes case {'error': final String message})
            CopyableError(message),
          if (changes case {
            'generation': final int _,
            'sessionId': final session,
          })
            _GenerationChanges(
              key: ValueKey('changes-${status['workspaceId']}-$session'),
              controller: controller,
            ),
          _DashboardPanel(
            title: 'Market candles',
            builder: (context) => _DashboardCandles(
              key: ValueKey('candles-${status['runId']}'),
              controller: controller,
            ),
          ),
          _DashboardPanel(
            title: 'Detailed strategy metrics',
            builder: widget.buildFullMetrics,
          ),
          _DashboardPanel(
            title: 'Trades and decisions',
            builder: (context) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _OpenTrades(accounts: widget.accounts, status: status),
                SizedBox(
                  height: 440,
                  child: SelectionContainer.disabled(
                    child: SelectionArea(
                      child: DecisionLogView(
                        events: controller.events,
                        status: status,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (status['strategyBests'] case final Map bests
              when bests.isNotEmpty)
            _StrategyBests(controller: controller, bests: bests),
          _DashboardPanel(
            title: 'Strategy readiness',
            builder: widget.buildReadiness,
          ),
          if (status['training'] case {'ready': true})
            _DashboardPanel(
              title: 'Model training',
              builder: (context) => _TrainingPanel(controller: controller),
            ),
        ],
      ),
    );
  }

  Widget _equityCard(BuildContext context) {
    final hasGenerations = widget.generationEquity.isNotEmpty;
    final chart = _chart == _OverviewChart.generations && !hasGenerations
        ? _OverviewChart.equity
        : _chart ??
              (hasGenerations
                  ? _OverviewChart.generations
                  : _OverviewChart.equity);
    final controller = widget.controller;
    final labels = widget.accounts
        .map((account) => '${account['label']}')
        .toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Portfolio equity',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (labels.isNotEmpty)
                  PopupMenuButton<String>(
                    tooltip: 'Show or hide portfolios',
                    icon: const Icon(Icons.filter_list),
                    onSelected: (label) =>
                        setState(() => controller.toggleSeries(label)),
                    itemBuilder: (context) => [
                      for (final label in labels)
                        CheckedPopupMenuItem(
                          value: label,
                          checked: !controller.hiddenSeries.contains(label),
                          child: Text(label),
                        ),
                    ],
                  ),
              ],
            ),
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SegmentedButton<_OverviewChart>(
                  showSelectedIcon: false,
                  segments: [
                    if (hasGenerations)
                      const ButtonSegment(
                        value: _OverviewChart.generations,
                        label: Text('Generations'),
                      ),
                    const ButtonSegment(
                      value: _OverviewChart.equity,
                      label: Text('Equity'),
                    ),
                    const ButtonSegment(
                      value: _OverviewChart.drawdown,
                      label: Text('Drawdown'),
                    ),
                  ],
                  selected: {chart},
                  onSelectionChanged: (value) =>
                      setState(() => _chart = value.single),
                ),
                if (chart != _OverviewChart.drawdown)
                  TextButton(
                    onPressed: () => setState(() => _dollars = !_dollars),
                    child: Text(_dollars ? 'USD' : 'Return %'),
                  ),
                if (chart == _OverviewChart.generations)
                  TextButton(
                    onPressed: () => setState(() => _showTrials = !_showTrials),
                    child: Text(_showTrials ? 'Tested' : 'Champion'),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 255,
              child: EquityChart(
                key: ValueKey(chart),
                accounts: chart == _OverviewChart.generations
                    ? widget.generationEquity
                    : widget.accounts,
                byGeneration: chart == _OverviewChart.generations,
                showTrialEquity: _showTrials,
                drawdown: chart == _OverviewChart.drawdown,
                percent: !_dollars,
                showStartingCash: chart != _OverviewChart.drawdown,
                colorsByLabel: widget.colors,
                hiddenLabels: controller.hiddenSeries,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OverviewMetrics extends StatefulWidget {
  const _OverviewMetrics({required this.accounts, required this.colors});
  final List<Map<String, dynamic>> accounts;
  final Map<String, Color> colors;

  @override
  State<_OverviewMetrics> createState() => _OverviewMetricsState();
}

class _OverviewMetricsState extends State<_OverviewMetrics> {
  static const columns = [
    ('netProfit', 'Net P&L'),
    ('returnPercent', 'Return'),
    ('winRatePercent', 'Win rate'),
    ('closedTrades', 'Closed'),
    ('maxDrawdownPercent', 'Max DD'),
  ];
  String _sort = 'netProfit';
  bool _ascending = false;

  @override
  Widget build(BuildContext context) {
    final rows =
        [
          for (final account in widget.accounts)
            (
              label: '${account['label']}',
              data: portfolioPerformance(account, defaultStartingCash: 10000),
            ),
        ]..sort((a, b) {
          final left = a.data[_sort] as num?;
          final right = b.data[_sort] as num?;
          if (left == null || right == null) {
            if (left == right) return a.label.compareTo(b.label);
            return left == null ? 1 : -1;
          }
          final order = left.compareTo(right);
          return order == 0
              ? a.label.compareTo(b.label)
              : (_ascending ? order : -order);
        });
    String display(String key, num? value) {
      if (value == null) return '—';
      return switch (key) {
        'netProfit' => _money(value.toDouble()),
        'closedTrades' => value.toInt().toString(),
        _ => '${value.toStringAsFixed(1)}%',
      };
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final visible = constraints.maxWidth < 480
                ? columns
                      .where(
                        (column) =>
                            column.$1 != 'netProfit' &&
                            column.$1 != 'maxDrawdownPercent',
                      )
                      .toList()
                : columns;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Portfolio performance',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (rows.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 18),
                    child: Text(
                      'Portfolio results appear after the simulation runs.',
                    ),
                  )
                else ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Expanded(flex: 3, child: Text('Strategy')),
                      for (final (key, title) in visible)
                        Expanded(
                          child: TextButton(
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 2,
                              ),
                              minimumSize: const Size(0, 32),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            onPressed: () => setState(() {
                              _ascending = _sort == key
                                  ? !_ascending
                                  : key == 'maxDrawdownPercent';
                              _sort = key;
                            }),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                _sort == key
                                    ? '$title ${_ascending ? '↑' : '↓'}'
                                    : title,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const Divider(height: 1),
                  SizedBox(
                    height: math.min(276, rows.length * 35.0),
                    child: SelectionContainer.disabled(
                      child: SelectionArea(
                        child: ListView.builder(
                          primary: false,
                          itemExtent: 35,
                          itemCount: rows.length,
                          itemBuilder: (context, index) {
                            final row = rows[index];
                            return Row(
                              children: [
                                Expanded(
                                  flex: 3,
                                  child: Padding(
                                    padding: const EdgeInsets.only(right: 6),
                                    child: Tooltip(
                                      message: row.label,
                                      child: Row(
                                        children: [
                                          Icon(
                                            Icons.circle,
                                            size: 7,
                                            color: widget.colors[row.label],
                                          ),
                                          const SizedBox(width: 5),
                                          Expanded(
                                            child: Text(
                                              row.label,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                                for (final (key, _) in visible)
                                  Expanded(
                                    child: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Text(
                                        display(key, row.data[key] as num?),
                                        style: TextStyle(
                                          color:
                                              key == 'returnPercent' ||
                                                  key == 'netProfit'
                                              ? _signedValueColor(
                                                  context,
                                                  (row.data[key] as num?) ?? 0,
                                                )
                                              : null,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _DashboardPanel extends StatefulWidget {
  const _DashboardPanel({required this.title, required this.builder});
  final String title;
  final WidgetBuilder builder;

  @override
  State<_DashboardPanel> createState() => _DashboardPanelState();
}

class _DashboardPanelState extends State<_DashboardPanel>
    with AutomaticKeepAliveClientMixin<_DashboardPanel> {
  bool _opened = false;

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Card(
      child: ExpansionTile(
        title: Text(widget.title),
        maintainState: true,
        onExpansionChanged: (open) {
          if (open && !_opened) setState(() => _opened = true);
        },
        children: [if (_opened) Builder(builder: widget.builder)],
      ),
    );
  }
}
