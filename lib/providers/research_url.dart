/// Lexical source-link guard shared by the backend and browser contract.
/// The backend additionally resolves DNS; neither side fetches source pages.
bool isPublicResearchUrl(Uri uri) {
  final host = uri.host.toLowerCase();
  if (uri.scheme != 'https' ||
      uri.port != 443 ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      uri.toString().length > 2000 ||
      RegExp(r'[\s\\<>"\x00-\x1f]').hasMatch(uri.toString()) ||
      !RegExp(
        r'^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$',
      ).hasMatch(host)) {
    return false;
  }
  return ![
    'localhost',
    'local',
    'internal',
    'lan',
    'home',
    'test',
    'invalid',
    'example',
    'onion',
    'arpa',
  ].any((suffix) => host == suffix || host.endsWith('.$suffix'));
}
