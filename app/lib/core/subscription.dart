import 'dart:async';
import 'dart:convert';
import 'dart:io';

const List<String> supportedSchemes = <String>[
  'vmess://',
  'vless://',
  'trojan://',
  'ss://',
  'ssr://',
  'hysteria2://',
  'hy2://',
  'tuic://',
  'wireguard://',
];

final RegExp _linkPattern = RegExp(
  r'(?:vmess|vless|trojan|ss|ssr|hysteria2|hy2|tuic|wireguard):\/\/\S+',
  caseSensitive: false,
);

class SourceResult {
  SourceResult({
    required this.url,
    required this.links,
    this.error = '',
  });

  final String url;
  final List<String> links;
  final String error;

  bool get ok => error.isEmpty;
}

String? _tryBase64(String data) {
  final String cleaned = data.replaceAll(RegExp(r'\s'), '');
  if (cleaned.isEmpty) {
    return null;
  }
  for (final Codec<List<int>, String> codec in <Codec<List<int>, String>>[
    base64,
    base64Url,
  ]) {
    for (int pad = 0; pad < 4; pad++) {
      try {
        final String padded = cleaned + '=' * pad;
        final String text = utf8.decode(
          codec.decode(padded),
          allowMalformed: true,
        );
        if (text.trim().isNotEmpty) {
          return text;
        }
      } catch (_) {
        continue;
      }
    }
  }
  return null;
}

String decodeBody(String body) {
  final String trimmed = body.trim();
  if (trimmed.isEmpty) {
    return '';
  }
  final String lower = trimmed.toLowerCase();
  for (final String scheme in supportedSchemes) {
    if (lower.contains(scheme)) {
      return trimmed;
    }
  }
  return _tryBase64(trimmed) ?? trimmed;
}

List<String> extractLinks(String text) {
  final List<String> links = <String>[];
  final Set<String> seen = <String>{};

  for (final String rawLine in text.split('\n')) {
    String line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#') || line.startsWith('//')) {
      continue;
    }
    final int head = line.length < 12 ? line.length : 12;
    if (line.contains('%') && !line.substring(0, head).contains('://')) {
      try {
        line = Uri.decodeFull(line).trim();
      } catch (_) {
        line = rawLine.trim();
      }
    }
    for (final RegExpMatch match in _linkPattern.allMatches(line)) {
      String link = match.group(0) ?? '';
      link = link.trim().replaceAll(RegExp(r'[,;]+$'), '');
      if (link.isEmpty || !seen.add(link)) {
        continue;
      }
      links.add(link);
    }
  }

  return links;
}

List<String> splitSourceList(String text) {
  final List<String> parts = <String>[];
  for (final String chunk in text.split(RegExp(r'[\n,;]+'))) {
    final String trimmed = chunk.trim();
    if (trimmed.isNotEmpty) {
      parts.add(trimmed);
    }
  }
  return parts;
}

class SubscriptionFetcher {
  SubscriptionFetcher({
    this.timeout = const Duration(seconds: 25),
    this.allowInvalidCertificates = false,
  });

  final Duration timeout;
  final bool allowInvalidCertificates;

  static const String _userAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  HttpClient _client() {
    final HttpClient client = HttpClient()
      ..connectionTimeout = timeout
      ..idleTimeout = const Duration(seconds: 5)
      ..userAgent = _userAgent;
    if (allowInvalidCertificates) {
      client.badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
    }
    return client;
  }

  Future<SourceResult> fetchOne(String url) async {
    final String trimmed = url.trim();
    if (trimmed.isEmpty) {
      return SourceResult(url: url, links: <String>[], error: 'empty url');
    }

    final String lower = trimmed.toLowerCase();
    for (final String scheme in supportedSchemes) {
      if (lower.startsWith(scheme)) {
        return SourceResult(url: trimmed, links: <String>[trimmed]);
      }
    }

    final Uri? uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return SourceResult(url: trimmed, links: <String>[], error: 'invalid url');
    }

    final HttpClient client = _client();
    try {
      final HttpClientRequest request =
          await client.getUrl(uri).timeout(timeout);
      request.followRedirects = true;
      request.maxRedirects = 5;
      request.headers.set(HttpHeaders.acceptHeader, '*/*');
      final HttpClientResponse response = await request.close().timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return SourceResult(
          url: trimmed,
          links: <String>[],
          error: 'http ${response.statusCode}',
        );
      }
      final List<int> bytes = await _collect(response).timeout(timeout);
      final String body = utf8.decode(bytes, allowMalformed: true);
      final List<String> links = extractLinks(decodeBody(body));
      if (links.isEmpty) {
        return SourceResult(
          url: trimmed,
          links: <String>[],
          error: 'no links found',
        );
      }
      return SourceResult(url: trimmed, links: links);
    } on TimeoutException {
      return SourceResult(url: trimmed, links: <String>[], error: 'timeout');
    } catch (error) {
      return SourceResult(
        url: trimmed,
        links: <String>[],
        error: _shortError(error),
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<List<String>> fetchAll(
    List<String> urls, {
    int concurrency = 8,
    void Function(int done, int total, SourceResult result)? onSource,
  }) async {
    final List<String> merged = <String>[];
    final Set<String> seen = <String>{};
    int done = 0;

    final List<String> queue = List<String>.from(urls);
    final int workers = concurrency < 1 ? 1 : concurrency;

    Future<void> worker() async {
      while (true) {
        String? next;
        if (queue.isNotEmpty) {
          next = queue.removeAt(0);
        }
        if (next == null) {
          return;
        }
        final SourceResult result = await fetchOne(next);
        done += 1;
        for (final String link in result.links) {
          if (seen.add(link)) {
            merged.add(link);
          }
        }
        if (onSource != null) {
          onSource(done, urls.length, result);
        }
      }
    }

    await Future.wait(<Future<void>>[
      for (int i = 0; i < workers; i++) worker(),
    ]);

    return merged;
  }

  static Future<List<int>> _collect(Stream<List<int>> stream) async {
    final List<int> bytes = <int>[];
    await for (final List<int> chunk in stream) {
      bytes.addAll(chunk);
      if (bytes.length > 12 * 1024 * 1024) {
        break;
      }
    }
    return bytes;
  }

  static String _shortError(Object error) {
    final String text = error.toString();
    if (text.length <= 90) {
      return text;
    }
    return '${text.substring(0, 90)}...';
  }
}
