part of 'main.dart';

/// Loads archived populations on demand so dashboard polling stays small.
class PopulationPerformance extends StatefulWidget {
  const PopulationPerformance({required this.controller, super.key});
  final DashboardController controller;

  @override
  State<PopulationPerformance> createState() => _PopulationPerformanceState();
}

class _PopulationPerformanceState extends State<PopulationPerformance>
    with AutomaticKeepAliveClientMixin<PopulationPerformance> {
  Map<String, dynamic>? _data;
  String? _error;
  String? _strategy;
  int? _generation;
  int _request = 0;
  bool _opened = false;
  bool _loading = false;
  int _sortColumn = 0;
  bool _ascending = true;

  @override
  bool get wantKeepAlive => true;
  @override
  void initState() {
    super.initState();
    _identity =
        '$_workspace:${(widget.controller.status['research'] as Map?)?['sessionId']}';
  }

  Object? get _workspace =>
      widget.controller.status['workspaceId'] ??
      widget.controller.status['runId'];
  int get _latest =>
      ((widget.controller.status['trainingSession'] as Map?)?['cycles']
          as int?) ??
      0;

  @override
  void didUpdateWidget(covariant PopulationPerformance oldWidget) {
    super.didUpdateWidget(oldWidget);
    final session =
        (widget.controller.status['research'] as Map?)?['sessionId'];
    final identity = '$_workspace:$session';
    if (_identity != identity) {
      _request++;
      _loading = false;
      _identity = identity;
      _generation = null;
      _data = null;
      _strategy = null;
    }
    if (_opened &&
        !_loading &&
        (_data == null ||
            (_generation == null && (_data!['generation'] ?? 0) != _latest))) {
      _load();
    }
  }

  String? _identity;

  Future<void> _load() async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final query = Uri(
        queryParameters: {
          'runId': '$_workspace',
          if (_generation != null) 'generation': '$_generation',
          'strategy': ?_strategy,
        },
      ).query;
      final data = await widget.controller.api.get(
        '/api/evolution/population?$query',
      );
      if (mounted && request == _request) {
        setState(() {
          _data = data;
          _strategy = data['strategy'] as String?;
        });
      }
    } catch (error) {
      if (mounted && request == _request) setState(() => _error = '$error');
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  Future<void> _details(Map member) async {
    try {
      final query = Uri(
        queryParameters: {
          'runId': '$_workspace',
          'generation': '${_data!['generation']}',
          'strategy': _strategy!,
          'individual': '${member['id']}',
        },
      ).query;
      final data = await widget.controller.api.get(
        '/api/evolution/population?$query',
      );
      if (!mounted) return;
      final individual = data['individual'] as Map;
      final account = Map<String, dynamic>.from(individual['account'] as Map);
      account['label'] = '${individual['id']}';
      await showSelectableDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            '$_strategy · ${individual['id']} · generation ${data['generation']}',
          ),
          content: SizedBox(
            width: 1000,
            height: 680,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Parents: ${(individual['parents'] as List).join(', ')} · '
                    'Born in generation ${individual['birthGeneration']} · '
                    'Mutation ${_num((individual['mutationAmount'] as num) * 100)}% · '
                    'Solidification ${_num((individual['solidification'] as num) * 100)}%',
                  ),
                  const SizedBox(height: 12),
                  const Text('Equity'),
                  SizedBox(
                    height: 200,
                    child: EquityChart(
                      accounts: [account],
                      showStartingCash: true,
                    ),
                  ),
                  const Text('Drawdown'),
                  SizedBox(
                    height: 100,
                    child: EquityChart(accounts: [account], drawdown: true),
                  ),
                  const SizedBox(height: 12),
                  const Text('Performance'),
                  Wrap(
                    spacing: 24,
                    runSpacing: 8,
                    children: [
                      for (final entry
                          in (individual['performance'] as Map).entries)
                        Text(
                          '${_readable('${entry.key}')}: ${entry.value is num ? _num(entry.value as num) : entry.value ?? '—'}',
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text('Variables'),
                  for (final entry in (individual['parameters'] as Map).entries)
                    Text('${entry.key}: ${entry.value}'),
                  const SizedBox(height: 12),
                  Text(
                    'Closed trade profit / loss: ${(account['closedPnl'] as List? ?? []).map((p) => _num(p as num)).join(', ')}',
                  ),
                  if ((account['events'] as List? ?? []).isNotEmpty)
                    SizedBox(
                      height: 340,
                      child: DecisionLogView(
                        title: 'Individual trades',
                        events: [
                          for (final e in account['events'] as List)
                            Map<String, dynamic>.from(e as Map),
                        ],
                        status: {
                          'strategies': [
                            {
                              'label': individual['id'],
                              'strategyId': individual['strategyId'],
                            },
                          ],
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton.icon(
              onPressed: () => copyAppText(
                context,
                const JsonEncoder.withIndent('  ').convert(individual),
              ),
              icon: const Icon(Icons.copy),
              label: const Text('Copy individual JSON'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  String _num(num? n) => n == null ? '—' : n.toStringAsFixed(2);
  void _navigate(int? generation) {
    setState(() => _generation = generation);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final generation = _data?['generation'] as int? ?? _latest;
    final rows = (_data?['individuals'] as List? ?? const [])
        .cast<Map>()
        .toList();
    Object? value(Map m, int col) => switch (col) {
      0 => m['rank'],
      1 => m['id'],
      2 => (m['parents'] as List).join(', '),
      3 => (m['performance'] as Map)['netProfit'],
      4 => (m['performance'] as Map)['returnPercent'],
      5 => (m['performance'] as Map)['winRatePercent'],
      6 => (m['performance'] as Map)['closedTrades'],
      7 => (m['performance'] as Map)['maxDrawdownPercent'],
      8 => m['fitness'],
      9 => m['mutationAmount'],
      _ => m['solidification'],
    };
    rows.sort((a, b) {
      final x = value(a, _sortColumn), y = value(b, _sortColumn);
      final result = x is num && y is num
          ? x.compareTo(y)
          : '$x'.compareTo('$y');
      return _ascending ? result : -result;
    });
    return Card(
      child: ExpansionTile(
        title: const Text('Population performance'),
        subtitle: Text(
          'Every individual · generation $generation · ${_generation == null ? 'Following latest' : 'Saved generation'}',
        ),
        maintainState: true,
        onExpansionChanged: (open) {
          _opened = open;
          if (open && _data == null) _load();
        },
        childrenPadding: const EdgeInsets.all(12),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              IconButton(
                tooltip: 'Previous population',
                onPressed: _loading || generation <= 1
                    ? null
                    : () => _navigate(generation - 1),
                icon: const Icon(Icons.chevron_left),
              ),
              Text('Generation $generation of $_latest'),
              IconButton(
                tooltip: 'Next population',
                onPressed: _loading || generation >= _latest
                    ? null
                    : () => _navigate(generation + 1),
                icon: const Icon(Icons.chevron_right),
              ),
              TextButton(
                onPressed: _generation == null ? null : () => _navigate(null),
                child: const Text('Follow latest'),
              ),
              if (_data?['strategy'] != null)
                DropdownButton<String>(
                  value: _strategy,
                  items: [
                    for (final label in _data!['strategies'] as List)
                      DropdownMenuItem(value: '$label', child: Text('$label')),
                  ],
                  onChanged: _loading
                      ? null
                      : (label) {
                          setState(() => _strategy = label);
                          _load();
                        },
                ),
            ],
          ),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null) CopyableError(_error!),
          if (!_loading && rows.isEmpty)
            const Text(
              'Individuals appear after a population generation completes. Older training sessions did not record populations.',
            ),
          const Text(
            'Champion is retained when profit and win rate do not regress. Select any individual for its variables, full metrics and equity history.',
          ),
          if (rows.isNotEmpty)
            SelectableHorizontalScrollView(
              child: DataTable(
                showCheckboxColumn: false,
                sortColumnIndex: _sortColumn,
                sortAscending: _ascending,
                columns: [
                  for (final (i, title) in [
                    'Rank',
                    'Individual',
                    'Parents',
                    'Net profit',
                    'Return %',
                    'Win %',
                    'Trades',
                    'Drawdown %',
                    'Fitness',
                    'Mutation %',
                    'Solidified %',
                  ].indexed)
                    DataColumn(
                      label: Text(title),
                      numeric: i != 1 && i != 2,
                      onSort: (column, ascending) => setState(() {
                        _sortColumn = column;
                        _ascending = ascending;
                      }),
                    ),
                ],
                rows: [
                  for (final m in rows)
                    DataRow(
                      selected: m['champion'] == true,
                      onSelectChanged: (_) => _details(m),
                      cells: [
                        DataCell(Text('${m['rank']}')),
                        DataCell(
                          Text(
                            '${m['id']}${m['champion'] == true
                                ? ' ★ champion'
                                : m['elite'] == true
                                ? ' · elite'
                                : ''}',
                          ),
                        ),
                        DataCell(Text((m['parents'] as List).join(', '))),
                        for (var i = 3; i <= 10; i++)
                          DataCell(
                            Text(
                              _num(
                                value(m, i) == null
                                    ? null
                                    : (value(m, i) as num) * (i >= 9 ? 100 : 1),
                              ),
                              style: i == 3
                                  ? TextStyle(
                                      color: _signedValueColor(
                                        context,
                                        value(m, i) as num,
                                      ),
                                    )
                                  : null,
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
