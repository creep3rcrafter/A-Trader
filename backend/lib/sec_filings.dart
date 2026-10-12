import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Maximum calendar span accepted by [SecFilingsClient.recentFilings].
const int secFilingsMaximumDateWindowDays = 366;

/// Maximum number of recent SEC submissions returned for a requested period.
const int secFilingsMaximumRecords = 10;

/// Maximum number of SEC requests made by one [SecFilingsClient.recentFilings].
const int secFilingsMaximumRequestsPerInvocation = 2;

/// Maximum number of requests permitted per injected client in a rolling minute.
const int secFilingsMaximumRequestsPerMinute = 10;

/// Maximum response sizes for the two fixed SEC JSON endpoints.
const int secFilingsMaximumTickerMapBytes = 8 * 1024 * 1024;
const int secFilingsMaximumSubmissionsBytes = 2 * 1024 * 1024;

/// Timeout applied independently to each SEC response and response body.
const Duration secFilingsRequestTimeout = Duration(seconds: 10);

/// SEC company ticker-to-CIK mapping endpoint.
const String secFilingsTickerMapUrl =
    'https://www.sec.gov/files/company_tickers.json';

/// Base URL for SEC issuer submissions; the client appends a zero-padded CIK.
const String secFilingsSubmissionsBaseUrl = 'https://data.sec.gov/submissions/';

const Duration _minimumRequestInterval = Duration(seconds: 1);
const Duration _maximumThrottleWait = Duration(seconds: 1);
const Duration _rollingQuotaWindow = Duration(minutes: 1);

final Expando<_SecRequestLimiter> _requestLimiters =
    Expando<_SecRequestLimiter>('SEC request limiters');

/// Reads recent SEC submissions using only the SEC ticker map and submissions
/// JSON endpoints. The injected client is never closed by this class.
///
/// [clock] defaults to DateTime.now and [delay] to Future.delayed. A fake delay
/// must advance its clock; shared HTTP clients use their first wrapper's clock
/// and delay. Response timeouts do not cancel the underlying HTTP operation.
class SecFilingsClient {
  SecFilingsClient({
    http.Client? client,
    DateTime Function()? clock,
    Future<void> Function(Duration)? delay,
    required this.permitted,
    required this.userAgent,
    this.timeout = secFilingsRequestTimeout,
  }) {
    _ownsClient = client == null;
    final effectiveClient = client ?? http.Client();
    final effectiveClock = clock ?? DateTime.now;
    _client = effectiveClient;
    _clock = effectiveClock;
    _limiter = _requestLimiters[effectiveClient] ??= _SecRequestLimiter(
      effectiveClock,
      delay ?? _defaultDelay,
    );
  }

  late final http.Client _client;
  late final DateTime Function() _clock;
  late final _SecRequestLimiter _limiter;
  late final bool _ownsClient;
  bool _closed = false;
  final bool permitted;
  final String userAgent;

  /// Maximum duration allowed for each HTTP response and its body.
  final Duration timeout;

  /// Whether access is permitted and the SEC request identity is valid.
  bool get enabled => permitted && _validUserAgent(userAgent);

  /// Whether this client created and therefore owns its HTTP client.
  bool get ownsClient => _ownsClient;

  /// Closes only a client created by this instance. Safe to call repeatedly.
  void close() {
    if (_ownsClient && !_closed) {
      _closed = true;
      _client.close();
    }
  }

  /// Returns normalized recent filings and provenance without exposing
  /// upstream response bodies or transport exception details.
  Future<Map<String, Object?>> recentFilings(
    String symbol, {
    required DateTime start,
    required DateTime end,
  }) async {
    final normalizedSymbol = symbol.trim().toUpperCase();
    final range = _validatedDateRange(start, end);

    if (!permitted) {
      return _unavailable(
        normalizedSymbol,
        start,
        end,
        'SEC data permission has not been granted.',
      );
    }
    if (!_validUserAgent(userAgent)) {
      return _unavailable(
        normalizedSymbol,
        start,
        end,
        'A valid identifying SEC user-agent with a contact email is required.',
      );
    }
    if (!_validSymbol(normalizedSymbol)) {
      return _unavailable(
        normalizedSymbol,
        start,
        end,
        'The ticker symbol is invalid.',
      );
    }
    if (range == null) {
      return _unavailable(
        normalizedSymbol,
        start,
        end,
        'The requested calendar date range is invalid or exceeds the allowed '
        '$secFilingsMaximumDateWindowDays-day window.',
      );
    }

    try {
      final tickerMap = await _requestJson(
        Uri.parse(secFilingsTickerMapUrl),
        maximumBytes: secFilingsMaximumTickerMapBytes,
      );
      final cik = _findCik(tickerMap, normalizedSymbol);
      if (cik == null) {
        return _unavailable(
          normalizedSymbol,
          start,
          end,
          'The SEC ticker map did not contain this ticker.',
        );
      }

      final cikPadded = cik.padLeft(10, '0');
      final submissionsUri = Uri.parse(
        '$secFilingsSubmissionsBaseUrl'
        'CIK$cikPadded.json',
      );
      final submissions = await _requestJson(
        submissionsUri,
        maximumBytes: secFilingsMaximumSubmissionsBytes,
      );
      final parsed = _parseSubmissions(
        submissions,
        cik: cik,
        symbol: normalizedSymbol,
        range: range,
      );
      final retrievedAt = _clock().toUtc().toIso8601String();
      final filings = parsed.map((filing) => filing.data).toList();
      final sources = parsed
          .map(
            (filing) => <String, Object?>{
              'url': filing.url,
              'title': '${filing.form} filing for $normalizedSymbol',
              'publishedAt': filing.data['filingDate'],
              'retrievedAt': retrievedAt,
            },
          )
          .toList();

      return {
        'status': 'ok',
        'data': filings,
        'metadata': _metadata(normalizedSymbol, start, end, cik, retrievedAt),
        'sources': sources,
        'limitations': <String>[
          if (parsed.isEmpty)
            'No recent SEC filings matched the requested calendar date window.',
        ],
      };
    } on _SecFailure catch (error) {
      return _unavailable(normalizedSymbol, start, end, error.limitation);
    } on http.ClientException {
      return _unavailable(
        normalizedSymbol,
        start,
        end,
        'An SEC request failed due to a network error.',
      );
    } on IOException {
      return _unavailable(
        normalizedSymbol,
        start,
        end,
        'An SEC request failed due to a network error.',
      );
    } on TimeoutException {
      return _unavailable(
        normalizedSymbol,
        start,
        end,
        'An SEC request timed out.',
      );
    } on FormatException {
      return _unavailable(
        normalizedSymbol,
        start,
        end,
        'The SEC returned malformed or oversized JSON data.',
      );
    }
  }

  Future<Object?> _requestJson(Uri uri, {required int maximumBytes}) async {
    return _limiter.execute(() => _sendJson(uri, maximumBytes: maximumBytes));
  }

  Future<Object?> _sendJson(Uri uri, {required int maximumBytes}) async {
    final request = http.Request('GET', uri)
      ..followRedirects = false
      ..maxRedirects = 0
      ..headers['Accept'] = 'application/json'
      ..headers['User-Agent'] = userAgent;
    final response = await _client.send(request).timeout(timeout);
    if (response.statusCode >= 300 && response.statusCode < 400) {
      await response.stream.listen((_) {}).cancel();
      throw const _SecFailure(
        'The SEC redirected the request; redirects are not followed.',
      );
    }
    if (response.statusCode != 200) {
      if (response.statusCode == 403 || response.statusCode == 429) {
        _limiter.suppress(response.headers['retry-after']);
      }
      await response.stream.listen((_) {}).cancel();
      throw _SecFailure(
        'The SEC request failed with HTTP status ${response.statusCode}.',
      );
    }
    if (response.contentLength case final length? when length > maximumBytes) {
      await response.stream.listen((_) {}).cancel();
      throw const FormatException('SEC response exceeds its size limit.');
    }

    final bytes = await _readBounded(
      response.stream,
      maximumBytes,
    ).timeout(timeout);
    return jsonDecode(utf8.decode(bytes));
  }

  Map<String, Object?> _metadata(
    String symbol,
    DateTime start,
    DateTime end,
    String cik,
    String retrievedAt,
  ) => {
    'symbol': symbol,
    'cik': cik,
    'start': _calendarDate(start),
    'end': _calendarDate(end),
    'retrievedAt': retrievedAt,
    'maximumRecords': secFilingsMaximumRecords,
  };

  Map<String, Object?> _unavailable(
    String symbol,
    DateTime start,
    DateTime end,
    String limitation,
  ) => {
    'status': 'unavailable',
    'data': <Map<String, Object?>>[],
    'metadata': {
      'symbol': symbol,
      'start': _calendarDate(start),
      'end': _calendarDate(end),
    },
    'sources': <Map<String, Object?>>[],
    'limitations': <String>[limitation],
  };
}

class _SecRequestLimiter {
  _SecRequestLimiter(this._clock, this._delay);

  final DateTime Function() _clock;
  final Future<void> Function(Duration) _delay;
  final List<DateTime> _requestTimes = [];
  DateTime? _lastRequestAt;
  DateTime? _blockedUntil;
  Future<void> _tail = Future<void>.value();

  Future<T> execute<T>(Future<T> Function() send) async {
    final queuedAt = _clock().toUtc();
    final previous = _tail;
    final completion = Completer<void>();
    _tail = previous.then((_) => completion.future);
    try {
      await previous.timeout(
        _maximumThrottleWait,
        onTimeout: () => throw const _SecFailure(
          'SEC request throttled while another per-client request is running.',
        ),
      );
      if (_clock().toUtc().difference(queuedAt) > _maximumThrottleWait ||
          !await _acquire(queuedAt)) {
        throw const _SecFailure(
          'SEC request throttled by the per-client request limit or cooldown.',
        );
      }
      final sentAt = _clock().toUtc();
      if ((_lastRequestAt != null &&
              sentAt.difference(_lastRequestAt!) < _minimumRequestInterval) ||
          (_blockedUntil != null && sentAt.isBefore(_blockedUntil!))) {
        throw const _SecFailure(
          'SEC request throttled by the per-client request limit or cooldown.',
        );
      }
      _requestTimes.add(sentAt);
      _lastRequestAt = sentAt;
      return await send();
    } finally {
      completion.complete();
    }
  }

  Future<bool> _acquire(DateTime queuedAt) async {
    var now = _clock().toUtc();
    if (_blockedUntil != null && now.isBefore(_blockedUntil!)) return false;
    _requestTimes.removeWhere(
      (requestTime) => now.difference(requestTime) >= _rollingQuotaWindow,
    );
    if (_requestTimes.length >= secFilingsMaximumRequestsPerMinute) {
      return false;
    }

    final lastRequestAt = _lastRequestAt;
    if (lastRequestAt != null) {
      final wait = lastRequestAt.add(_minimumRequestInterval).difference(now);
      if (wait > Duration.zero &&
          wait + now.difference(queuedAt) > _maximumThrottleWait) {
        return false;
      }
      if (wait > Duration.zero) {
        await _delay(wait);
        now = _clock().toUtc();
        if (now.difference(lastRequestAt) < _minimumRequestInterval) {
          return false;
        }
      }
    }
    if (_blockedUntil != null && now.isBefore(_blockedUntil!)) return false;
    return true;
  }

  void suppress(String? retryAfter) {
    final now = _clock().toUtc();
    var until = now.add(_rollingQuotaWindow);
    if (retryAfter != null) {
      DateTime? requestedUntil;
      final value = retryAfter.trim();
      final seconds = RegExp(r'^[0-9]+$').hasMatch(value)
          ? BigInt.tryParse(value)
          : null;
      if (seconds != null) {
        final maximumDate = DateTime.fromMillisecondsSinceEpoch(
          8640000000000000,
          isUtc: true,
        );
        final maximumSeconds = maximumDate.difference(now).inSeconds;
        requestedUntil = seconds > BigInt.from(maximumSeconds)
            ? maximumDate
            : now.add(Duration(seconds: seconds.toInt()));
      } else {
        try {
          requestedUntil = HttpDate.parse(retryAfter).toUtc();
        } on FormatException {
          // Invalid Retry-After values retain the minimum cooldown.
        } on HttpException {
          // HttpDate also reports invalid date syntax as HttpException.
        }
      }
      if (requestedUntil != null && requestedUntil.isAfter(until)) {
        until = requestedUntil;
      }
    }
    if (_blockedUntil == null || until.isAfter(_blockedUntil!)) {
      _blockedUntil = until;
    }
  }
}

Future<void> _defaultDelay(Duration duration) => Future<void>.delayed(duration);

class _SecFailure implements Exception {
  const _SecFailure(this.limitation);

  final String limitation;
}

class _Filing {
  _Filing({
    required this.form,
    required this.publishedAt,
    required this.url,
    required this.data,
  });

  final String form;
  final DateTime publishedAt;
  final String url;
  final Map<String, Object?> data;
}

Future<Uint8List> _readBounded(
  Stream<List<int>> stream,
  int maximumBytes,
) async {
  final builder = BytesBuilder(copy: false);
  var totalBytes = 0;
  await for (final chunk in stream) {
    totalBytes += chunk.length;
    if (totalBytes > maximumBytes) {
      throw const FormatException('SEC response exceeds its size limit.');
    }
    builder.add(chunk);
  }
  return builder.takeBytes();
}

List<_Filing> _parseSubmissions(
  Object? value, {
  required String cik,
  required String symbol,
  required ({DateTime start, DateTime end}) range,
}) {
  final document = _stringMap(value);
  if (_normalizeCik(document['cik']) != cik) {
    throw const FormatException('SEC submissions CIK does not match.');
  }
  final filings = _stringMap(document['filings']);
  final recent = _stringMap(filings['recent']);
  final forms = _stringList(recent['form']);
  final filingDates = _stringList(recent['filingDate']);
  final accessions = _stringList(recent['accessionNumber']);
  final documents = _stringList(recent['primaryDocument']);
  final length = forms.length;
  if (filingDates.length != length ||
      accessions.length != length ||
      documents.length != length) {
    throw const FormatException('SEC recent filing arrays are misaligned.');
  }

  final results = <_Filing>[];
  for (var index = 0; index < length; index++) {
    final filingDate = _parseCalendarDate(filingDates[index]);
    final accession = accessions[index];
    final primaryDocument = documents[index];
    if (forms[index].isEmpty ||
        !_validAccession(accession) ||
        !_validPrimaryDocument(primaryDocument)) {
      throw const FormatException('SEC filing data is invalid.');
    }
    if (filingDate.isBefore(range.start) || filingDate.isAfter(range.end)) {
      continue;
    }

    final accessionPath = accession.replaceAll('-', '');
    final url =
        'https://www.sec.gov/Archives/edgar/data/'
        '$cik/$accessionPath/$primaryDocument';
    results.add(
      _Filing(
        form: forms[index],
        publishedAt: filingDate,
        url: url,
        data: {
          'form': forms[index],
          'filingDate': filingDates[index],
          'accessionNumber': accession,
          'primaryDocument': primaryDocument,
          'url': url,
        },
      ),
    );
  }

  results.sort((left, right) => right.publishedAt.compareTo(left.publishedAt));
  return results.take(secFilingsMaximumRecords).toList();
}

String? _findCik(Object? value, String symbol) {
  if (value is! Map) {
    throw const FormatException('SEC ticker map has an invalid shape.');
  }
  for (final entry in value.values) {
    final company = _stringMap(entry);
    final ticker = company['ticker'];
    if (ticker is String && ticker.trim().toUpperCase() == symbol) {
      final cik = _normalizeCik(company['cik_str']);
      if (cik == null) {
        throw const FormatException('SEC ticker map has an invalid CIK.');
      }
      return cik;
    }
  }
  return null;
}

Map<String, Object?> _stringMap(Object? value) {
  if (value is! Map) {
    throw const FormatException('SEC JSON has an invalid object shape.');
  }
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw const FormatException('SEC JSON has an invalid object key.');
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}

List<String> _stringList(Object? value) {
  if (value is! List || value.any((element) => element is! String)) {
    throw const FormatException('SEC recent filing arrays are invalid.');
  }
  return value.cast<String>();
}

String? _normalizeCik(Object? value) {
  if (value is! int && value is! String) return null;
  final digits = value.toString();
  if (!RegExp(r'^[0-9]{1,10}$').hasMatch(digits)) return null;
  final numeric = int.tryParse(digits);
  if (numeric == null || numeric <= 0) return null;
  return numeric.toString();
}

({DateTime start, DateTime end})? _validatedDateRange(
  DateTime start,
  DateTime end,
) {
  final startDate = DateTime.utc(start.year, start.month, start.day);
  final endDate = DateTime.utc(end.year, end.month, end.day);
  if (endDate.isBefore(startDate) ||
      endDate.difference(startDate) >=
          const Duration(days: secFilingsMaximumDateWindowDays)) {
    return null;
  }
  return (start: startDate, end: endDate);
}

DateTime _parseCalendarDate(String value) {
  final match = RegExp(r'^([0-9]{4})-([0-9]{2})-([0-9]{2})$').firstMatch(value);
  if (match == null) {
    throw const FormatException('SEC filing date is invalid.');
  }
  final year = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final day = int.parse(match[3]!);
  final date = DateTime.utc(year, month, day);
  if (date.year != year || date.month != month || date.day != day) {
    throw const FormatException('SEC filing date is invalid.');
  }
  return date;
}

String _calendarDate(DateTime value) {
  final date = DateTime.utc(value.year, value.month, value.day);
  return '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}

bool _validSymbol(String symbol) =>
    RegExp(r'^[A-Z0-9][A-Z0-9.-]{0,9}$').hasMatch(symbol);

bool _validAccession(String value) =>
    RegExp(r'^[0-9]{10}-[0-9]{2}-[0-9]{6}$').hasMatch(value);

bool _validPrimaryDocument(String value) =>
    value.length <= 255 &&
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(value) &&
    !value.contains('..');

bool _validUserAgent(String value) {
  if (value.length > 200 ||
      value.trim() != value ||
      value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
    return false;
  }
  final email = RegExp(
    r'[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}',
    caseSensitive: false,
  ).firstMatch(value);
  if (email == null || email.start == 0) return false;
  final identifier = value.substring(0, email.start).trim();
  return identifier.isNotEmpty &&
      !identifier.contains('@') &&
      !identifier.contains(RegExp(r'[\r\n]'));
}
