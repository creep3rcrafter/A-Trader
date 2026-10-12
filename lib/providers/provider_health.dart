import 'dart:convert';

import 'package:http/http.dart' as http;

import 'local_service_url.dart';

class ProviderHealthException implements Exception {
  const ProviderHealthException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ProviderConnectionStatus {
  const ProviderConnectionStatus({
    required this.id,
    required this.credentialsPresent,
    required this.enabled,
    required this.integrationImplemented,
    this.termsConfirmed = false,
  });

  final String id;
  final bool credentialsPresent;
  final bool enabled;
  final bool integrationImplemented;
  final bool termsConfirmed;

  factory ProviderConnectionStatus.fromJson(
    String id,
    Map<String, dynamic> json,
  ) {
    return ProviderConnectionStatus(
      id: id,
      credentialsPresent: _requiredBool(json, 'credentialsPresent'),
      enabled: _requiredBool(json, 'enabled'),
      integrationImplemented: _requiredBool(json, 'integrationImplemented'),
      termsConfirmed: json['termsConfirmed'] == true,
    );
  }

  static bool _requiredBool(Map<String, dynamic> json, String field) {
    final value = json[field];
    if (value is! bool) {
      throw FormatException('Provider status is missing boolean $field.');
    }
    return value;
  }
}

class ProviderHealthSnapshot {
  const ProviderHealthSnapshot({required this.status, required this.providers});

  final String status;
  final Map<String, ProviderConnectionStatus> providers;

  factory ProviderHealthSnapshot.fromJson(Map<String, dynamic> json) {
    if (json['status'] != 'ok') {
      throw const FormatException('Local service health status is not ok.');
    }
    final rawProviders = json['providers'];
    if (rawProviders is! Map<String, dynamic>) {
      throw const FormatException(
        'Local service health response has no provider status map.',
      );
    }
    final providers = <String, ProviderConnectionStatus>{};
    for (final entry in rawProviders.entries) {
      final value = entry.value;
      if (value is! Map<String, dynamic>) {
        throw FormatException('Invalid status for provider ${entry.key}.');
      }
      providers[entry.key] = ProviderConnectionStatus.fromJson(
        entry.key,
        value,
      );
    }
    return ProviderHealthSnapshot(status: 'ok', providers: providers);
  }
}

class ProviderHealthService {
  ProviderHealthService({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  Future<ProviderHealthSnapshot> check(Uri backendUri) async {
    if (!isLocalServiceUri(backendUri)) {
      throw const ProviderHealthException(
        'Provider checks must use loopback or the same server as this web app.',
      );
    }

    final healthUri = backendUri.replace(
      path: '/health',
      query: null,
      fragment: null,
    );
    late final http.Response response;
    try {
      final request = http.Request('GET', healthUri)..followRedirects = false;
      response = await http.Response.fromStream(
        await _client.send(request).timeout(const Duration(seconds: 5)),
      ).timeout(const Duration(seconds: 5));
    } on Exception {
      throw const ProviderHealthException(
        'Could not reach the local service. Start it and check the URL.',
      );
    }
    if (response.statusCode == 401) {
      throw const ProviderHealthException(
        'Session expired. Reload this page to sign in again.',
      );
    }
    if (response.statusCode != 200) {
      throw ProviderHealthException(
        'Local service returned HTTP ${response.statusCode}.',
      );
    }

    late final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const ProviderHealthException(
        'Local service returned invalid health data.',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const ProviderHealthException(
        'Local service returned an invalid health response.',
      );
    }
    try {
      return ProviderHealthSnapshot.fromJson(decoded);
    } on FormatException {
      throw const ProviderHealthException(
        'Local service returned invalid health data.',
      );
    }
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
