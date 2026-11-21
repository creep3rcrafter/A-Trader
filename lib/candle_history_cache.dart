import 'dart:convert';
import 'dart:io';

import 'exchange_calendar.dart';
import 'historical_replay.dart';

typedef MinuteHistoryDownload =
    Future<List<MinuteBar>> Function({
      required String symbol,
      required DateTime startUtc,
      required DateTime endUtc,
    });

/// Shared, durable one-minute history. Past regular sessions are retained;
/// partial/current sessions remain refreshable and never become final early.
class CandleHistoryCache {
  CandleHistoryCache({
    required this.directory,
    required this.download,
    required this.clock,
  });
  final Directory directory;
  final MinuteHistoryDownload download;
  final DateTime Function() clock;
  final _knownFiles = <String>{};
  final _symbols = <String>{};
  final _memory = <String, Map<String, dynamic>>{};
  final _pending = <String, Future<List<MinuteBar>>>{};
  int cacheHits = 0, downloads = 0;
  String lastActivity = 'Saved candle data is reused automatically.';

  Map<String, Object?> get status => {
    'storedDays': _knownFiles.length,
    'symbols': _symbols.toList()..sort(),
    'cacheHits': cacheHits,
    'downloads': downloads,
    'activity': lastActivity,
    'directory': directory.path,
  };

  Future<void> initialize() async {
    if (!await directory.exists()) return;
    await for (final folder in directory.list()) {
      if (folder is! Directory) continue;
      await for (final file in folder.list()) {
        if (file is File && file.path.endsWith('.json.gz')) {
          _knownFiles.add(file.uri.toString());
          _symbols.add(
            Uri.decodeComponent(
              folder.uri.pathSegments.where((s) => s.isNotEmpty).last,
            ),
          );
        }
      }
    }
  }

  Future<DateTime?> latestCompleteDay(String symbol) async {
    final folder = Directory(
      '${directory.path}/${Uri.encodeComponent(symbol)}',
    );
    if (!await folder.exists()) return null;
    final names = [
      await for (final item in folder.list())
        if (item is File &&
            RegExp(r'\d{4}-\d{2}-\d{2}\.json\.gz$').hasMatch(item.path))
          item.uri.pathSegments.last,
    ];
    names.sort((a, b) => b.compareTo(a));
    for (final name in names) {
      final day = DateTime.parse('${name.substring(0, 10)}T00:00:00Z');
      if ((await _read(symbol, day))?['complete'] == true) return day;
    }
    return null;
  }

  Future<List<MinuteBar>> fetch({
    required String symbol,
    required DateTime startUtc,
    required DateTime endUtc,
  }) async {
    symbol = symbol.trim().toUpperCase();
    if (!RegExp(r'^[A-Z0-9.$^/\-]{1,24}$').hasMatch(symbol)) {
      throw ArgumentError('Invalid candle-data symbol.');
    }
    if (!endUtc.isAfter(startUtc)) return [];
    // Overlapping callers share completed downloads instead of racing writes.
    final previous = _pending[symbol];
    final ready = previous == null
        ? Future<void>.value()
        : previous.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    final job = ready.then(
      (_) => _fetch(symbol, startUtc.toUtc(), endUtc.toUtc()),
    );
    _pending[symbol] = job;
    try {
      return await job;
    } finally {
      if (identical(_pending[symbol], job)) _pending.remove(symbol);
    }
  }

  Future<List<MinuteBar>> _fetch(
    String symbol,
    DateTime start,
    DateTime end,
  ) async {
    final days = <DateTime>[];
    for (
      var day = DateTime.utc(start.year, start.month, start.day);
      day.isBefore(end);
      day = day.add(const Duration(days: 1))
    ) {
      final session = _session(day);
      if (session != null) {
        final open = UsEquityCalendar.easternToUtc(
          DateTime(day.year, day.month, day.day, 9, 30),
        );
        final close = open.add(Duration(minutes: session.durationMinutes));
        if (start.isBefore(close) && end.isAfter(open)) days.add(day);
      }
    }
    final found = <String, List<MinuteBar>>{};
    final missing = <DateTime>[];
    for (final day in days) {
      final cached = await _read(symbol, day);
      final now = clock().toUtc();
      final today = DateTime.utc(now.year, now.month, now.day);
      final freshPartial =
          cached != null &&
          (cached['bars'] as List).isNotEmpty &&
          !day.isBefore(today) &&
          now.difference(DateTime.parse(cached['fetchedAt'] as String)) <
              const Duration(minutes: 1);
      if (cached != null && (cached['complete'] == true || freshPartial)) {
        found[_date(day)] = _decodeBars(symbol, cached['bars'] as List);
        cacheHits++;
      } else {
        missing.add(day);
      }
    }
    for (var i = 0; i < missing.length;) {
      final from = missing[i];
      var last = i;
      bool adjacent(DateTime left, DateTime right) {
        for (
          var day = left.add(const Duration(days: 1));
          day.isBefore(right);
          day = day.add(const Duration(days: 1))
        ) {
          if (_session(day) != null) return false;
        }
        return true;
      }

      while (last + 1 < missing.length &&
          adjacent(missing[last], missing[last + 1]) &&
          missing[last + 1].difference(from).inDays < 28) {
        last++;
      }
      final through = missing[last].add(const Duration(days: 1));
      lastActivity =
          'Downloading missing 1m candles: $symbol ${_date(from)} to ${_date(missing[last])}';
      final rows = await download(
        symbol: symbol,
        startUtc: from,
        endUtc: through.isAfter(clock().toUtc()) ? clock().toUtc() : through,
      );
      downloads++;
      for (var j = i; j <= last; j++) {
        final day = missing[j], next = missing[j].add(const Duration(days: 1));
        final bars = _clean(
          symbol,
          rows.where(
            (bar) => !bar.openTime.isBefore(day) && bar.openTime.isBefore(next),
          ),
        );
        found[_date(day)] = bars;
        await _write(
          symbol,
          day,
          bars,
          complete: bars.isNotEmpty && _finished(day),
        );
      }
      i = last + 1;
    }
    lastActivity = missing.isEmpty
        ? 'Using saved 1m candles for $symbol'
        : 'Saved downloaded 1m candles for $symbol';
    return [for (final day in days) ...found[_date(day)]!]
        .where(
          (bar) => !bar.openTime.isBefore(start) && bar.openTime.isBefore(end),
        )
        .toList();
  }

  /// Reuse complete sessions already present in an older saved training job.
  Future<void> remember(String symbol, List<MinuteBar> rows) async {
    final grouped = <String, List<MinuteBar>>{};
    for (final bar in rows) {
      (grouped[_date(bar.openTime.toUtc())] ??= []).add(bar);
    }
    for (final entry in grouped.entries) {
      final day = DateTime.parse('${entry.key}T00:00:00Z');
      final session = _session(day);
      if (session == null || !_finished(day)) continue;
      if ((await _read(symbol, day))?['complete'] == true) continue;
      final bars = _clean(symbol, entry.value);
      if (bars.isEmpty) continue;
      final open = UsEquityCalendar.easternToUtc(
        DateTime(day.year, day.month, day.day, 9, 30),
      );
      final close = open.add(Duration(minutes: session.durationMinutes));
      if (!bars.first.openTime.isAfter(open) &&
          !bars.last.openTime.add(const Duration(minutes: 1)).isBefore(close)) {
        await _write(symbol, day, bars, complete: true);
      }
    }
  }

  EquitySession? _session(DateTime day) =>
      UsEquityCalendar.forDate(DateTime.utc(day.year, day.month, day.day, 16));
  bool _finished(DateTime day) {
    final session = _session(day);
    if (session == null) return true;
    final close = UsEquityCalendar.easternToUtc(
      DateTime(
        day.year,
        day.month,
        day.day,
        session.closeMinute ~/ 60,
        session.closeMinute % 60,
      ),
    );
    return !clock().toUtc().isBefore(close.add(const Duration(minutes: 15)));
  }

  String _date(DateTime day) =>
      '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
  File _file(String symbol, DateTime day) => File(
    '${directory.path}/${Uri.encodeComponent(symbol)}/${_date(day)}.json.gz',
  );

  Future<Map<String, dynamic>?> _read(String symbol, DateTime day) async {
    final file = _file(symbol, day);
    if (_memory[file.path] case final cached?) return cached;
    try {
      if (!await file.exists()) return null;
      final raw =
          jsonDecode(utf8.decode(gzip.decode(await file.readAsBytes())))
              as Map<String, dynamic>;
      if (raw['version'] != 1 ||
          raw['symbol'] != symbol ||
          raw['date'] != _date(day)) {
        return null;
      }
      final bars = _decodeBars(symbol, raw['bars'] as List);
      if (raw['intervalMinutes'] != 1 ||
          bars.length != (raw['bars'] as List).length ||
          bars.any((bar) => _date(bar.openTime.toUtc()) != _date(day))) {
        return null;
      }
      _retain(file.path, raw);
      return raw;
    } catch (_) {
      return null;
    }
  }

  void _retain(String path, Map<String, dynamic> raw) {
    _memory.remove(path);
    _memory[path] = raw;
    if (_memory.length > 128) _memory.remove(_memory.keys.first);
  }

  Future<void> _write(
    String symbol,
    DateTime day,
    List<MinuteBar> bars, {
    required bool complete,
  }) async {
    final file = _file(symbol, day);
    final raw = <String, dynamic>{
      'version': 1,
      'symbol': symbol,
      'date': _date(day),
      'intervalMinutes': 1,
      'complete': complete,
      'fetchedAt': clock().toUtc().toIso8601String(),
      'bars': [
        for (final bar in bars)
          {
            'time': bar.openTime.toUtc().toIso8601String(),
            'open': bar.open,
            'high': bar.high,
            'low': bar.low,
            'close': bar.close,
            'volume': bar.volume,
          },
      ],
    };
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsBytes(
      gzip.encode(utf8.encode(jsonEncode(raw))),
      flush: true,
    );
    await temporary.rename(file.path);
    _knownFiles.add(file.uri.toString());
    _symbols.add(symbol);
    _retain(file.path, raw);
  }

  List<MinuteBar> _decodeBars(String symbol, List rows) => _clean(symbol, [
    for (final row in rows.cast<Map>())
      MinuteBar(
        symbol: symbol,
        openTime: DateTime.parse(row['time'] as String),
        open: (row['open'] as num).toDouble(),
        high: (row['high'] as num).toDouble(),
        low: (row['low'] as num).toDouble(),
        close: (row['close'] as num).toDouble(),
        volume: (row['volume'] as num).toDouble(),
      ),
  ]);
  List<MinuteBar> _clean(String symbol, Iterable<MinuteBar> rows) {
    final byTime = <int, MinuteBar>{};
    for (final bar in rows) {
      if (bar.symbol == symbol &&
          [
            bar.open,
            bar.high,
            bar.low,
            bar.close,
            bar.volume,
          ].every((value) => value.isFinite) &&
          bar.low > 0 &&
          bar.high >= bar.open &&
          bar.high >= bar.close &&
          bar.low <= bar.open &&
          bar.low <= bar.close &&
          bar.volume >= 0 &&
          !bar.openTime
              .add(const Duration(minutes: 1))
              .isAfter(clock().toUtc())) {
        byTime[bar.openTime.millisecondsSinceEpoch] = bar;
      }
    }
    return byTime.values.toList()
      ..sort((a, b) => a.openTime.compareTo(b.openTime));
  }
}
