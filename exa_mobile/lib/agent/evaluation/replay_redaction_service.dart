import 'models/replay_trace.dart';

/// Strips private values from replay traces before storage. Traces default
/// to redacted; full traces require the explicit local-diagnostics setting.
///
/// Redacted: email addresses, message/body fields, phone numbers, file
/// paths, and anything that looks like a credential. Structure, ids, tool
/// names, counts, and statuses are preserved - that is what replay needs.
class ReplayRedactionService {
  const ReplayRedactionService();

  static final _emailPattern =
      RegExp(r'[\w.+-]+@[\w-]+\.[\w.]+', caseSensitive: false);
  static final _phonePattern =
      RegExp(r'(?<!\d)(\+?\d[\d\s\-().]{7,}\d)(?!\d)');
  static final _windowsPathPattern =
      RegExp(r'[A-Za-z]:\\[^\s"<>|]+|/(?:data|storage|home)/[^\s"<>|]+');
  static final _secretPattern = RegExp(
      r'(sk-[A-Za-z0-9\-_]{8,}|Bearer\s+[A-Za-z0-9\-_.]+|AIza[A-Za-z0-9\-_]{20,})');

  /// Keys whose string values are dropped wholesale (bodies and other long
  /// private content), keeping only a length marker.
  static const _droppedKeys = {
    'body', 'extracted_text', 'content_summary', 'text',
  };

  ReplayTrace redact(ReplayTrace trace) => trace.copyWith(
        userRequest: redactText(trace.userRequest),
        memoriesProvided: [
          for (final memory in trace.memoriesProvided) _redactMap(memory),
        ],
        activeEntities: [
          for (final entity in trace.activeEntities) _redactMap(entity),
        ],
        toolExecutions: [
          for (final execution in trace.toolExecutions) _redactMap(execution),
        ],
        executionReport: _redactMap(trace.executionReport),
        finalResponse: _redactMap(trace.finalResponse),
        userFeedback: trace.userFeedback == null
            ? null
            : _redactMap(trace.userFeedback!),
        containsSensitiveData: false,
      );

  String redactText(String text) => text
      .replaceAll(_secretPattern, '[redacted-secret]')
      .replaceAll(_emailPattern, '[email]')
      .replaceAll(_phonePattern, '[phone]')
      .replaceAll(_windowsPathPattern, '[path]');

  Map<String, dynamic> _redactMap(Map<String, dynamic> map) {
    final redacted = <String, dynamic>{};
    map.forEach((key, value) {
      if (_droppedKeys.contains(key) && value is String) {
        redacted[key] = '[redacted ${value.length} chars]';
        return;
      }
      redacted[key] = _redactValue(value);
    });
    return redacted;
  }

  Object? _redactValue(Object? value) {
    if (value is String) return redactText(value);
    if (value is Map) {
      return _redactMap(value.cast<String, dynamic>());
    }
    if (value is List) {
      return [for (final item in value) _redactValue(item)];
    }
    return value;
  }
}
