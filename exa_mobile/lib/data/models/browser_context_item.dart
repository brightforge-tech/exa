class BrowserContextItem {
  final String id;
  final String? sessionId;
  final String? pageTitle;
  final String? pageUrl;
  final String? contentSummary;
  final String? extractedText;
  final String sourceApp;
  final DateTime createdAt;

  const BrowserContextItem({
    required this.id,
    this.sessionId,
    this.pageTitle,
    this.pageUrl,
    this.contentSummary,
    this.extractedText,
    this.sourceApp = 'browser',
    required this.createdAt,
  });

  Map<String, Object?> toRow() => {
        'id': id,
        'session_id': sessionId,
        'page_title': pageTitle,
        'page_url': pageUrl,
        'content_summary': contentSummary,
        'extracted_text': extractedText,
        'source_app': sourceApp,
        'created_at': createdAt.toIso8601String(),
      };

  factory BrowserContextItem.fromRow(Map<String, Object?> row) =>
      BrowserContextItem(
        id: row['id'] as String,
        sessionId: row['session_id'] as String?,
        pageTitle: row['page_title'] as String?,
        pageUrl: row['page_url'] as String?,
        contentSummary: row['content_summary'] as String?,
        extractedText: row['extracted_text'] as String?,
        sourceApp: row['source_app'] as String? ?? 'browser',
        createdAt:
            DateTime.tryParse(row['created_at'] as String? ?? '') ??
                DateTime.now(),
      );

  Map<String, Object?> toAgentJson({bool includeText = false}) => {
        'id': id,
        if (pageTitle != null) 'page_title': pageTitle,
        if (pageUrl != null) 'page_url': pageUrl,
        if (contentSummary != null) 'content_summary': contentSummary,
        'shared_at': createdAt.toIso8601String(),
        if (includeText && extractedText != null)
          'extracted_text': extractedText,
      };
}
