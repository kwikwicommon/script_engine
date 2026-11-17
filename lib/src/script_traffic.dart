/// The request and response fields a script can read.
class ScriptTraffic {
  const ScriptTraffic({
    required this.id,
    required this.method,
    required this.url,
    this.host = '',
    this.path = '',
    this.query = '',
    this.requestHeaders = const <String, String>{},
    this.requestBodyText = '',
    this.statusCode,
    this.responseHeaders = const <String, String>{},
    this.responseBodyText = '',
  });

  final String id;
  final String method;
  final String url;
  final String host;
  final String path;
  final String query;
  final Map<String, String> requestHeaders;
  final String requestBodyText;
  final int? statusCode;
  final Map<String, String> responseHeaders;
  final String responseBodyText;
}
