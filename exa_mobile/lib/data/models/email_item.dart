class EmailItem {
  final String id;
  final String subject;
  final String? sender;
  final DateTime? receivedAt;
  final String body;
  final String? summary;
  final String source;
  final String? accountId;
  final bool digested;
  final DateTime createdAt;

  const EmailItem({
    required this.id,
    required this.subject,
    this.sender,
    this.receivedAt,
    required this.body,
    this.summary,
    this.source = 'manual',
    this.accountId,
    this.digested = false,
    required this.createdAt,
  });

  Map<String, Object?> toRow() => {
        'id': id,
        'subject': subject,
        'sender': sender,
        'received_at': receivedAt?.toIso8601String(),
        'body': body,
        'summary': summary,
        'source': source,
        'account_id': accountId,
        'digested': digested ? 1 : 0,
        'created_at': createdAt.toIso8601String(),
      };

  factory EmailItem.fromRow(Map<String, Object?> row) => EmailItem(
        id: row['id'] as String,
        subject: row['subject'] as String,
        sender: row['sender'] as String?,
        receivedAt: row['received_at'] is String
            ? DateTime.tryParse(row['received_at'] as String)
            : null,
        body: row['body'] as String,
        summary: row['summary'] as String?,
        source: row['source'] as String? ?? 'manual',
        accountId: row['account_id'] as String?,
        digested: (row['digested'] as int? ?? 0) == 1,
        createdAt:
            DateTime.tryParse(row['created_at'] as String? ?? '') ??
                DateTime.now(),
      );

  Map<String, Object?> toAgentJson({bool includeBody = false}) => {
        'id': id,
        'subject': subject,
        if (sender != null) 'from': sender,
        if (receivedAt != null)
          'received_at': receivedAt!.toIso8601String(),
        'added_at': createdAt.toIso8601String(),
        'digested': digested,
        if (summary != null) 'summary': summary,
        if (includeBody) 'body': body,
      };
}
