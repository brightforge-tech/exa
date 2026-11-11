class ToolCallLog {
  final String id;
  final String toolName;
  final String? inputJson;
  final String? outputJson;
  final String status;
  final String? errorMessage;
  final DateTime createdAt;

  const ToolCallLog({
    required this.id,
    required this.toolName,
    this.inputJson,
    this.outputJson,
    required this.status,
    this.errorMessage,
    required this.createdAt,
  });

  Map<String, Object?> toRow() => {
        'id': id,
        'tool_name': toolName,
        'input_json': inputJson,
        'output_json': outputJson,
        'status': status,
        'error_message': errorMessage,
        'created_at': createdAt.toIso8601String(),
      };

  factory ToolCallLog.fromRow(Map<String, Object?> row) => ToolCallLog(
        id: row['id'] as String,
        toolName: row['tool_name'] as String,
        inputJson: row['input_json'] as String?,
        outputJson: row['output_json'] as String?,
        status: row['status'] as String,
        errorMessage: row['error_message'] as String?,
        createdAt: DateTime.tryParse(row['created_at'] as String? ?? '') ??
            DateTime.now(),
      );
}
