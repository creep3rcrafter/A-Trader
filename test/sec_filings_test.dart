import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// The backend implementation is intentionally outside the Flutter lib tree.
// ignore: avoid_relative_lib_imports
import '../backend/lib/sec_filings.dart';

const _userAgent = 'A-Trader/1.0 (sec-contact@example.com)';
final _start = DateTime.utc(2025, 1, 1);
final _end = DateTime.utc(2025, 12, 31);

void main() {
  test(
    'queued concurrent wrapper cannot bypass a newly received cooldown',
    () async {
      final time = _FakeTime(DateTime.utc(2026, 10, 11));
      final response = Completer<http.Response>();
      final started = Completer<void>();
      var calls = 0;
      final httpClient = MockClient((_) async {
        calls++;
        started.complete();
        return response.future;
      });
      SecFilingsClient wrapper() => SecFilingsClient(
        client: httpClient,
        clock: time.clock,
        delay: time.delay,
        permitted: true,
        userAgent: _userAgent,
      );
      final first = wrapper().recentFilings('AAPL', start: _start, end: _end);
      await started.future;
      final second = wrapper().recentFilings('AAPL', start: _start, end: _end);
      response.complete(http.Response('private body', 429));
      final results = await Future.wait([first, second]);
      expect(calls, 1);
      expect(results[1]['limitations'], contains(contains('cooldown')));
    },
  );

  test(
    'rolling quota is shared across wrappers and expires after a minute',
    () async {
      final time = _FakeTime(DateTime.utc(2026, 10, 11));
      var calls = 0;
      final httpClient = MockClient((_) async {
        calls++;
        return _jsonResponse({});
      });
      SecFilingsClient wrapper() => SecFilingsClient(
        client: httpClient,
        clock: time.clock,
        delay: time.delay,
        permitted: true,
        userAgent: _userAgent,
      );
      final first = wrapper();
      final second = wrapper();
      for (var index = 0; index < 10; index++) {
        await (index.isEven ? first : second).recentFilings(
          'AAPL',
          start: _start,
          end: _end,
        );
      }
      final blocked = await second.recentFilings(
        'AAPL',
        start: _start,
        end: _end,
      );
      expect(blocked['limitations'], contains(contains('throttled')));
      expect(calls, 10);
      time.now = DateTime.utc(2026, 10, 11, 0, 1);
      await first.recentFilings('AAPL', start: _start, end: _end);
      expect(calls, 11);
    },
  );

  test(
    'rejects declared and streamed bodies above each endpoint limit',
    () async {
      for (final submissions in [false, true]) {
        for (final declared in [false, true]) {
          final time = _FakeTime(DateTime.utc(2026, 10, 11));
          var calls = 0;
          final limit = submissions
              ? secFilingsMaximumSubmissionsBytes
              : secFilingsMaximumTickerMapBytes;
          final client = _StreamClient((request) async {
            calls++;
            if (submissions && calls == 1) {
              return http.StreamedResponse(
                Stream.value(
                  utf8.encode(
                    jsonEncode({
                      '0': {'cik_str': 320193, 'ticker': 'AAPL'},
                    }),
                  ),
                ),
                200,
              );
            }
            return http.StreamedResponse(
              declared
                  ? const Stream<List<int>>.empty()
                  : Stream.fromIterable([
                      List<int>.filled(limit, 32),
                      [32],
                    ]),
              200,
              contentLength: declared ? limit + 1 : null,
            );
          });
          final service = SecFilingsClient(
            client: client,
            clock: time.clock,
            delay: time.delay,
            permitted: true,
            userAgent: _userAgent,
          );
          final result = await service.recentFilings(
            'AAPL',
            start: _start,
            end: _end,
          );
          expect(result['status'], 'unavailable');
          expect(result['limitations'], contains(contains('oversized')));
          expect(calls, submissions ? 2 : 1);
        }
      }
    },
  );

  test('sanitizes malformed JSON, arrays, and accessions', () async {
    final valid = _submissions(
      cik: 320193,
      filingDates: ['2025-05-01'],
      accessions: ['0000320193-25-000001'],
      documents: ['form4.xml'],
    );
    final malformed = <String>[
      'raw private body',
      jsonEncode({
        'cik': 320193,
        'filings': {'recent': {}},
      }),
      jsonEncode(
        _submissions(
          cik: 320193,
          filingDates: ['2025-05-01'],
          accessions: [],
          documents: ['form4.xml'],
        ),
      ),
      jsonEncode(
        _submissions(
          cik: 320193,
          filingDates: ['2025-05-01'],
          accessions: ['../private-accession'],
          documents: ['form4.xml'],
        ),
      ),
    ];
    final wrongType = jsonDecode(jsonEncode(valid)) as Map<String, dynamic>;
    wrongType['filings']['recent']['form'] = [4];
    malformed.add(jsonEncode(wrongType));
    for (final body in malformed) {
      final time = _FakeTime(DateTime.utc(2026, 10, 11));
      final service = SecFilingsClient(
        client: MockClient(
          (request) async => request.url.toString() == secFilingsTickerMapUrl
              ? _jsonResponse({
                  '0': {'cik_str': 320193, 'ticker': 'AAPL'},
                })
              : http.Response(body, 200),
        ),
        clock: time.clock,
        delay: time.delay,
        permitted: true,
        userAgent: _userAgent,
      );
      final result = await service.recentFilings(
        'AAPL',
        start: _start,
        end: _end,
      );
      expect(result['status'], 'unavailable');
      expect(result.toString(), isNot(contains('private')));
      expect(result['sources'], isA<List<Map<String, Object?>>>());
      expect(result['limitations'], isA<List<String>>());
    }
  });

  test('sanitizes transport failures and send/body timeouts', () async {
    for (final kind in ['client', 'io', 'sendTimeout', 'bodyTimeout']) {
      final stream = StreamController<List<int>>();
      final service = SecFilingsClient(
        client: _StreamClient((_) async {
          switch (kind) {
            case 'client':
              throw http.ClientException('private transport detail');
            case 'io':
              throw const SocketException('private socket detail');
            case 'sendTimeout':
              return Completer<http.StreamedResponse>().future;
            default:
              return http.StreamedResponse(stream.stream, 200);
          }
        }),
        permitted: true,
        userAgent: _userAgent,
        timeout: const Duration(milliseconds: 5),
      );
      final result = await service.recentFilings(
        'AAPL',
        start: _start,
        end: _end,
      );
      expect(result['status'], 'unavailable');
      expect(result.toString(), isNot(contains('private')));
      expect(
        result['limitations'],
        contains(contains(kind.endsWith('Timeout') ? 'timed out' : 'network')),
      );
      if (kind == 'bodyTimeout') {
        await stream.close();
      }
    }
  });

  test(
    '403/429 cooldown is shared, at least a minute, and honors Retry-After',
    () async {
      for (final status in [403, 429]) {
        for (final retryAfter in [
          null,
          'invalid',
          '1',
          '120',
          HttpDate.format(DateTime.utc(2026, 10, 11, 0, 2)),
        ]) {
          final time = _FakeTime(DateTime.utc(2026, 10, 11));
          var calls = 0;
          final httpClient = MockClient((_) async {
            calls++;
            return http.Response(
              'private body',
              status,
              headers: {'retry-after': ?retryAfter},
            );
          });
          SecFilingsClient wrapper() => SecFilingsClient(
            client: httpClient,
            clock: time.clock,
            delay: time.delay,
            permitted: true,
            userAgent: _userAgent,
          );
          final first = wrapper();
          final second = wrapper();
          expect(
            (await first.recentFilings(
              'AAPL',
              start: _start,
              end: _end,
            ))['status'],
            'unavailable',
          );
          time.now = time.now.add(const Duration(seconds: 59));
          final blocked = await second.recentFilings(
            'AAPL',
            start: _start,
            end: _end,
          );
          expect(blocked['limitations'], contains(contains('cooldown')));
          expect(calls, 1);
          final longer =
              retryAfter == '120' ||
              retryAfter == 'Sun, 11 Oct 2026 00:02:00 GMT';
          time.now = DateTime.utc(2026, 10, 11, 0, 1);
          await second.recentFilings('AAPL', start: _start, end: _end);
          expect(calls, longer ? 1 : 2);
          if (longer) {
            time.now = DateTime.utc(2026, 10, 11, 0, 2);
            await second.recentFilings('AAPL', start: _start, end: _end);
            expect(calls, 2);
          }
        }
      }
    },
  );

  test(
    'shared-client concurrent sends stay spaced after a scheduler stall',
    () async {
      final time = _FakeTime(DateTime.utc(2026, 10, 11));
      final sent = <DateTime>[];
      var delayCount = 0;
      final httpClient = MockClient((_) async {
        sent.add(time.now);
        return _jsonResponse({});
      });
      SecFilingsClient wrapper() => SecFilingsClient(
        client: httpClient,
        clock: time.clock,
        delay: (wait) async {
          delayCount++;
          await time.delay(delayCount == 1 ? const Duration(seconds: 5) : wait);
        },
        permitted: true,
        userAgent: _userAgent,
      );
      final first = wrapper();
      final second = wrapper();
      await first.recentFilings('AAPL', start: _start, end: _end);
      await Future.wait([
        first.recentFilings('AAPL', start: _start, end: _end),
        second.recentFilings('AAPL', start: _start, end: _end),
      ]);
      // The queued call is rejected once its wait exceeds one second.
      expect(sent, hasLength(2));
      await second.recentFilings('AAPL', start: _start, end: _end);
      expect(sent, hasLength(3));
      expect(sent[1].difference(sent[0]), const Duration(seconds: 5));
      expect(sent[2].difference(sent[1]), const Duration(seconds: 1));
    },
  );

  test(
    'unchanged fake clock fails closed after delay rather than bursting',
    () async {
      var calls = 0;
      final service = SecFilingsClient(
        client: MockClient((_) async {
          calls++;
          return _jsonResponse({
            '0': {'cik_str': 320193, 'ticker': 'AAPL'},
          });
        }),
        clock: () => DateTime.utc(2026, 10, 11),
        delay: (_) async {},
        permitted: true,
        userAgent: _userAgent,
      );
      final result = await service.recentFilings(
        'AAPL',
        start: _start,
        end: _end,
      );
      expect(result['status'], 'unavailable');
      expect(calls, 1);
    },
  );

  test(
    'maps ticker, filters dates, and returns safe SEC links and times',
    () async {
      final requests = <http.BaseRequest>[];
      final client = MockClient((request) async {
        requests.add(request);
        expect(request.method, 'GET');
        expect(request.followRedirects, isFalse);
        expect(request.headers['user-agent'], _userAgent);
        if (requests.length == 1) {
          expect(request.url.toString(), secFilingsTickerMapUrl);
          return _jsonResponse({
            '0': {'cik_str': 320193, 'ticker': 'AAPL', 'title': 'Apple Inc.'},
          });
        }
        expect(
          request.url.toString(),
          '${secFilingsSubmissionsBaseUrl}CIK0000320193.json',
        );
        return _jsonResponse(
          _submissions(
            cik: 320193,
            filingDates: ['2025-08-04', '2024-12-31', '2025-02-03'],
            accessions: [
              '0000320193-25-000001',
              '0000320193-24-000001',
              '0000320193-25-000002',
            ],
            documents: ['form4.xml', 'form8k.htm', 'form4b.xml'],
          ),
        );
      });
      final time = _FakeTime(DateTime.utc(2026, 10, 11, 20));
      final service = SecFilingsClient(
        client: client,
        clock: time.clock,
        delay: time.delay,
        permitted: true,
        userAgent: _userAgent,
      );
      expect(service.enabled, isTrue);

      final result = await service.recentFilings(
        ' aapl ',
        start: _start,
        end: _end,
      );

      expect(result['status'], 'ok');
      expect(requests, hasLength(secFilingsMaximumRequestsPerInvocation));
      expect(result['metadata'], {
        'symbol': 'AAPL',
        'cik': '320193',
        'start': '2025-01-01',
        'end': '2025-12-31',
        'retrievedAt': '2026-10-11T20:00:01.000Z',
        'maximumRecords': secFilingsMaximumRecords,
      });
      final data = result['data']! as List<Map<String, Object?>>;
      expect(data, hasLength(2));
      expect(data.first['filingDate'], '2025-08-04');
      expect(
        data.first['url'],
        'https://www.sec.gov/Archives/edgar/data/'
        '320193/000032019325000001/form4.xml',
      );
      final sources = result['sources']! as List<Map<String, Object?>>;
      expect(sources, hasLength(2));
      expect(sources.first['title'], '4 filing for AAPL');
      expect(sources.first['publishedAt'], '2025-08-04');
      expect(sources.first['retrievedAt'], '2026-10-11T20:00:01.000Z');
      expect(result['limitations'], isEmpty);
    },
  );

  test(
    'permission and invalid user-agent prevent all requests explicitly',
    () async {
      var requestCount = 0;
      http.Client client() => MockClient((_) async {
        requestCount++;
        return _jsonResponse({});
      });

      final denied = SecFilingsClient(
        client: client(),
        clock: DateTime.now,
        permitted: false,
        userAgent: _userAgent,
      );
      final missingIdentity = SecFilingsClient(
        client: client(),
        clock: DateTime.now,
        permitted: true,
        userAgent: 'A-Trader',
      );
      expect(denied.enabled, isFalse);
      expect(missingIdentity.enabled, isFalse);

      final deniedResult = await denied.recentFilings(
        'AAPL',
        start: _start,
        end: _end,
      );
      final invalidAgentResult = await missingIdentity.recentFilings(
        'AAPL',
        start: _start,
        end: _end,
      );
      expect(deniedResult['status'], 'unavailable');
      expect(
        (deniedResult['limitations']! as List<String>).single,
        contains('permission'),
      );
      expect(invalidAgentResult['status'], 'unavailable');
      expect(
        (invalidAgentResult['limitations']! as List<String>).single,
        contains('contact email'),
      );
      expect(requestCount, 0);
    },
  );

  test('supports production constructor defaults for client and clock', () {
    final service = SecFilingsClient(permitted: true, userAgent: _userAgent);
    expect(service.enabled, isTrue);
    expect(service.ownsClient, isTrue);
    service.close();
    service.close();
  });

  test('does not close a caller-owned injected HTTP client', () async {
    final injectedClient = MockClient((_) async => _jsonResponse({}));
    final service = SecFilingsClient(
      client: injectedClient,
      permitted: true,
      userAgent: _userAgent,
    );
    expect(service.ownsClient, isFalse);

    service.close();
    expect(
      (await injectedClient.get(
        Uri.parse('https://fixture.invalid'),
      )).statusCode,
      200,
    );
    injectedClient.close();
  });

  test('rejects unsafe archive filenames and mismatched issuer CIK', () async {
    for (final document in ['../form4.xml', 'form%2f4.xml', 'https://bad']) {
      final service = _serviceWithSubmissions(
        _submissions(
          cik: 320193,
          filingDates: ['2025-05-01'],
          accessions: ['0000320193-25-000001'],
          documents: [document],
        ),
      );
      final result = await service.recentFilings(
        'AAPL',
        start: _start,
        end: _end,
      );
      expect(result['status'], 'unavailable', reason: document);
      expect(result.toString(), isNot(contains(document)));
    }

    final mismatch = await _serviceWithSubmissions(
      _submissions(
        cik: 789019,
        filingDates: ['2025-05-01'],
        accessions: ['0000320193-25-000001'],
        documents: ['form4.xml'],
      ),
    ).recentFilings('AAPL', start: _start, end: _end);
    expect(mismatch['status'], 'unavailable');
  });

  test(
    'returns a successful empty result for no matching recent filings',
    () async {
      final result = await _serviceWithSubmissions(
        _submissions(
          cik: 320193,
          filingDates: ['2024-12-31'],
          accessions: ['0000320193-24-000001'],
          documents: ['form4.xml'],
        ),
      ).recentFilings('AAPL', start: _start, end: _end);

      expect(result['status'], 'ok');
      expect(result['data'], isEmpty);
      expect(result['sources'], isEmpty);
      expect(result['limitations'], isNotEmpty);
    },
  );

  test(
    'rejects impossible filing dates and date windows outside the bound',
    () async {
      final malformedDate = await _serviceWithSubmissions(
        _submissions(
          cik: 320193,
          filingDates: ['2025-02-30'],
          accessions: ['0000320193-25-000001'],
          documents: ['form4.xml'],
        ),
      ).recentFilings('AAPL', start: _start, end: _end);
      expect(malformedDate['status'], 'unavailable');

      var requestCount = 0;
      final outsideBound = SecFilingsClient(
        client: MockClient((_) async {
          requestCount++;
          return _jsonResponse({});
        }),
        clock: DateTime.now,
        permitted: true,
        userAgent: _userAgent,
      );
      final result = await outsideBound.recentFilings(
        'AAPL',
        start: DateTime.utc(2024),
        end: DateTime.utc(2025),
      );
      expect(result['status'], 'unavailable');
      expect(requestCount, 0);
    },
  );

  test('returns at most ten most recent filings', () async {
    final result = await _serviceWithSubmissions(
      _submissions(
        cik: 320193,
        filingDates: [
          for (var day = 1; day <= 12; day++)
            '2025-01-${day.toString().padLeft(2, '0')}',
        ],
        accessions: [
          for (var index = 1; index <= 12; index++)
            '0000320193-25-${index.toString().padLeft(6, '0')}',
        ],
        documents: List<String>.filled(12, 'form4.xml'),
      ),
    ).recentFilings('AAPL', start: _start, end: _end);

    final data = result['data']! as List<Map<String, Object?>>;
    expect(data, hasLength(secFilingsMaximumRecords));
    expect(data.first['filingDate'], '2025-01-12');
    expect(data.last['filingDate'], '2025-01-03');
  });

  test(
    'sanitizes SEC HTTP errors and refuses redirects without following them',
    () async {
      for (final statusCode in [403, 429, 302]) {
        var requestCount = 0;
        final service = SecFilingsClient(
          client: MockClient((request) async {
            requestCount++;
            expect(request.followRedirects, isFalse);
            return http.Response('sensitive upstream body', statusCode);
          }),
          clock: DateTime.now,
          permitted: true,
          userAgent: _userAgent,
        );

        final result = await service.recentFilings(
          'AAPL',
          start: _start,
          end: _end,
        );
        expect(result['status'], 'unavailable');
        expect(requestCount, 1);
        expect(result.toString(), isNot(contains('sensitive upstream body')));
        if (statusCode == 403 || statusCode == 429) {
          expect(
            (result['limitations']! as List<String>).single,
            contains('$statusCode'),
          );
        } else {
          expect(
            (result['limitations']! as List<String>).single,
            contains('redirected'),
          );
        }
      }
    },
  );

  test(
    'enforces the shared ten-request rolling quota per injected client',
    () async {
      final time = _FakeTime(DateTime.utc(2026, 10, 11));
      var requestCount = 0;
      final sharedClient = MockClient((request) async {
        requestCount++;
        if (request.url.toString() == secFilingsTickerMapUrl) {
          return _jsonResponse({
            '0': {'cik_str': 320193, 'ticker': 'AAPL'},
          });
        }
        return _jsonResponse(
          _submissions(
            cik: 320193,
            filingDates: [],
            accessions: [],
            documents: [],
          ),
        );
      });
      final service = SecFilingsClient(
        client: sharedClient,
        clock: time.clock,
        delay: time.delay,
        permitted: true,
        userAgent: _userAgent,
      );

      for (
        var call = 0;
        call < secFilingsMaximumRequestsPerMinute ~/ 2;
        call++
      ) {
        expect(
          (await service.recentFilings(
            'AAPL',
            start: _start,
            end: _end,
          ))['status'],
          'ok',
        );
      }
      final throttled = await service.recentFilings(
        'AAPL',
        start: _start,
        end: _end,
      );
      expect(throttled['status'], 'unavailable');
      expect(requestCount, secFilingsMaximumRequestsPerMinute);
      expect(
        (throttled['limitations']! as List<String>).single,
        contains('throttled'),
      );
    },
  );
}

SecFilingsClient _serviceWithSubmissions(Map<String, Object?> submissions) {
  var requestCount = 0;
  final time = _FakeTime(DateTime.utc(2026, 10, 11));
  return SecFilingsClient(
    client: MockClient((request) async {
      requestCount++;
      if (requestCount == 1) {
        return _jsonResponse({
          '0': {'cik_str': 320193, 'ticker': 'AAPL'},
        });
      }
      return _jsonResponse(submissions);
    }),
    clock: time.clock,
    delay: time.delay,
    permitted: true,
    userAgent: _userAgent,
  );
}

Map<String, Object?> _submissions({
  required Object cik,
  required List<String> filingDates,
  required List<String> accessions,
  required List<String> documents,
}) => {
  'cik': cik,
  'filings': {
    'recent': {
      'form': List<String>.filled(filingDates.length, '4'),
      'filingDate': filingDates,
      'accessionNumber': accessions,
      'primaryDocument': documents,
    },
  },
};

http.Response _jsonResponse(Object? body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

class _FakeTime {
  _FakeTime(this.now);

  DateTime now;
  DateTime clock() => now;
  Future<void> delay(Duration duration) async {
    now = now.add(duration);
  }
}

class _StreamClient extends http.BaseClient {
  _StreamClient(this.handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}
