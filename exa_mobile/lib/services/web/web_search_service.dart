import 'dart:convert';

import 'package:http/http.dart' as http;

/// One hit from a web search.
class WebSearchResult {
  const WebSearchResult({
    required this.title,
    required this.url,
    this.snippet = '',
  });

  final String title;
  final String url;
  final String snippet;

  Map<String, Object?> toAgentJson() => {
        'title': title,
        'url': url,
        if (snippet.isNotEmpty) 'snippet': snippet,
      };
}

/// A public web page reduced to readable text.
class WebPage {
  const WebPage({
    required this.url,
    required this.title,
    required this.text,
    required this.truncated,
  });

  final String url;
  final String title;
  final String text;
  final bool truncated;
}

class WebSearchException implements Exception {
  const WebSearchException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Searches the public web and reads pages, for questions Exa cannot answer
/// from what it knows or from the user's own data.
///
/// Uses DuckDuckGo's HTML endpoint: no account, no API key, and no profile
/// built from the queries - the nearest a search can get to Exa's
/// local-first promise. Only the query and the address of a page the agent
/// chose to read leave the phone; nothing of the user's own data does,
/// unless the model put it in the query, which the tool description tells
/// it not to.
class WebSearchService {
  WebSearchService({http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final http.Client _http;

  static const timeout = Duration(seconds: 20);

  /// The most page text handed to the model. A long article is mostly
  /// navigation and boilerplate past this, and the turn has other work.
  static const maxPageChars = 8000;

  /// The most bytes downloaded for one page.
  static const maxPageBytes = 1500000;

  static const _headers = {
    // A plain browser identity: the HTML endpoint serves a different (or
    // no) page to clients that call themselves bots.
    'user-agent': 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36',
    'accept': 'text/html,application/xhtml+xml',
    'accept-language': 'en',
  };

  Future<List<WebSearchResult>> search(String query, {int limit = 6}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      throw const WebSearchException('The search query is empty.');
    }
    http.Response response;
    try {
      response = await _http
          .post(
            Uri.parse('https://html.duckduckgo.com/html/'),
            headers: {
              ..._headers,
              'content-type': 'application/x-www-form-urlencoded',
            },
            body: {'q': trimmed},
          )
          .timeout(timeout);
    } catch (e) {
      throw WebSearchException('Could not reach the search service: $e');
    }
    if (response.statusCode != 200) {
      throw WebSearchException(
          'The search service refused the request (HTTP '
          '${response.statusCode}). Try again in a moment.');
    }
    return parseResults(response.body, limit: limit);
  }

  /// Pulls results out of DuckDuckGo's HTML results page. Public so the
  /// parser can be tested against a saved page without the network.
  static List<WebSearchResult> parseResults(String html, {int limit = 6}) {
    final results = <WebSearchResult>[];
    final seen = <String>{};
    final anchor = RegExp(
      r'<a[^>]+class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>(.*?)</a>',
      dotAll: true,
    );
    final snippet = RegExp(
      r'class="[^"]*result__snippet[^"]*"[^>]*>(.*?)</(?:a|div|td)>',
      dotAll: true,
    );
    final anchors = anchor.allMatches(html).toList();
    for (var i = 0; i < anchors.length && results.length < limit; i++) {
      final match = anchors[i];
      final url = _resolveRedirect(_decodeEntities(match.group(1)!));
      if (url == null || !seen.add(url)) continue;
      // Ads link through DuckDuckGo's own ad redirector.
      if (url.contains('duckduckgo.com/y.js')) continue;
      final end =
          i + 1 < anchors.length ? anchors[i + 1].start : html.length;
      final tail = html.substring(match.end, end);
      final snippetMatch = snippet.firstMatch(tail);
      results.add(WebSearchResult(
        title: _clean(match.group(2)!),
        url: url,
        snippet: snippetMatch == null ? '' : _clean(snippetMatch.group(1)!),
      ));
    }
    return results;
  }

  /// Result links point at a redirector carrying the real address in
  /// `uddg`; the model should see, and the user be shown, the real one.
  static String? _resolveRedirect(String href) {
    var link = href;
    if (link.startsWith('//')) link = 'https:$link';
    final uri = Uri.tryParse(link);
    if (uri == null) return null;
    final target = uri.queryParameters['uddg'];
    if (target != null && target.isNotEmpty) return target;
    if (uri.scheme == 'http' || uri.scheme == 'https') return link;
    return null;
  }

  Future<WebPage> read(String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty) {
      throw const WebSearchException(
          'That is not a web address (it must start with http:// or '
          'https://).');
    }
    if (_isPrivateHost(uri.host)) {
      throw const WebSearchException(
          'Exa only reads public web pages, not addresses on the local '
          'network.');
    }
    http.StreamedResponse response;
    final List<int> bytes;
    try {
      final request = http.Request('GET', uri)..headers.addAll(_headers);
      response = await _http.send(request).timeout(timeout);
      final collected = <int>[];
      await for (final chunk in response.stream.timeout(timeout)) {
        collected.addAll(chunk);
        if (collected.length >= maxPageBytes) break;
      }
      bytes = collected;
    } catch (e) {
      throw WebSearchException('Could not load the page: $e');
    }
    if (response.statusCode >= 400) {
      throw WebSearchException(
          'The site answered HTTP ${response.statusCode} for that page.');
    }
    final type = response.headers['content-type'] ?? '';
    if (type.isNotEmpty &&
        !type.contains('html') &&
        !type.contains('text') &&
        !type.contains('xml') &&
        !type.contains('json')) {
      throw WebSearchException(
          'That address is not a readable page (it serves $type).');
    }
    final raw = utf8.decode(bytes, allowMalformed: true);
    final isHtml = type.isEmpty || type.contains('html');
    final title = isHtml ? _titleOf(raw) : '';
    final text = isHtml ? htmlToText(raw) : raw.trim();
    final truncated = text.length > maxPageChars;
    return WebPage(
      url: uri.toString(),
      title: title,
      text: truncated ? '${text.substring(0, maxPageChars)}...' : text,
      truncated: truncated,
    );
  }

  static bool _isPrivateHost(String host) {
    final h = host.toLowerCase();
    if (h == 'localhost' || h.endsWith('.local') || h.endsWith('.lan')) {
      return true;
    }
    final ipv4 = RegExp(r'^(\d+)\.(\d+)\.(\d+)\.(\d+)$').firstMatch(h);
    if (ipv4 != null) {
      final a = int.parse(ipv4.group(1)!);
      final b = int.parse(ipv4.group(2)!);
      return a == 10 ||
          a == 127 ||
          a == 0 ||
          (a == 169 && b == 254) ||
          (a == 172 && b >= 16 && b <= 31) ||
          (a == 192 && b == 168) ||
          (a == 100 && b >= 64 && b <= 127);
    }
    return h.startsWith('[') || h.contains(':');
  }

  static String _titleOf(String html) {
    final match = RegExp(r'<title[^>]*>(.*?)</title>',
            caseSensitive: false, dotAll: true)
        .firstMatch(html);
    return match == null ? '' : _clean(match.group(1)!);
  }

  /// Readable text from an HTML document: scripts, styles and page chrome
  /// dropped, block elements turned into line breaks, entities decoded.
  static String htmlToText(String html) {
    var text = html.replaceAll(
        RegExp(
            r'<(script|style|noscript|svg|head|nav|footer|form|iframe)'
            r'\b[^>]*>.*?</\1>',
            caseSensitive: false,
            dotAll: true),
        ' ');
    text = text.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), ' ');
    text = text.replaceAll(
        RegExp(r'<(br|/p|/div|/li|/h[1-6]|/tr|/section|/article)\b[^>]*>',
            caseSensitive: false),
        '\n');
    text = text.replaceAll(RegExp(r'<li\b[^>]*>', caseSensitive: false), '\n- ');
    text = text.replaceAll(RegExp(r'<[^>]+>'), ' ');
    text = _decodeEntities(text);
    final lines = [
      for (final line in text.split('\n'))
        if (line.replaceAll(RegExp(r'\s+'), ' ').trim() case final clean
            when clean.isNotEmpty && clean != '-')
          clean,
    ];
    return lines.join('\n');
  }

  static String _clean(String fragment) => _decodeEntities(
          fragment.replaceAll(RegExp(r'<[^>]+>'), ''))
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static String _decodeEntities(String text) => text
      .replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'),
          (m) => _char(int.tryParse(m.group(1)!, radix: 16)))
      .replaceAllMapped(
          RegExp(r'&#(\d+);'), (m) => _char(int.tryParse(m.group(1)!)))
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');

  static String _char(int? code) =>
      code == null || code <= 0 || code > 0x10FFFF
          ? ''
          : String.fromCharCode(code);

  void dispose() => _http.close();
}
