import 'package:flutter/foundation.dart';

bool isLocalServiceUri(Uri uri) {
  return isTrustedServiceUri(uri, browserOrigin: kIsWeb ? Uri.base : null);
}

bool isTrustedServiceUri(Uri uri, {Uri? browserOrigin}) {
  if (uri.userInfo.isNotEmpty) return false;
  final loopback =
      uri.scheme == 'http' &&
      (uri.host == 'localhost' ||
          uri.host == '127.0.0.1' ||
          uri.host == '::1' ||
          uri.host == '[::1]');
  final sameOrigin =
      browserOrigin != null &&
      (browserOrigin.scheme == 'http' || browserOrigin.scheme == 'https') &&
      uri.scheme == browserOrigin.scheme &&
      uri.host == browserOrigin.host &&
      uri.port == browserOrigin.port;
  return loopback || sameOrigin;
}

String defaultServiceUrl() =>
    kIsWeb && const bool.fromEnvironment('A_TRADER_SAME_ORIGIN')
    ? Uri.base.origin
    : 'http://127.0.0.1:8765';
