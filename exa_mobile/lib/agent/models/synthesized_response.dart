import 'dart:convert';

import 'turn_contract.dart';

/// A factual claim the final response makes about completed work, declared
/// by the synthesis model so the verifier can check it against the
/// execution report instead of parsing prose.
class ResponseClaim {
  const ResponseClaim({
    required this.type,
    required this.description,
    this.entityId,
  });

  /// e.g. task_created, event_created, email_sent, emails_digested,
  /// messages_digested, reminder_created, file_stored, rule_changed.
  final String type;
  final String description;
  final String? entityId;

  Map<String, Object?> toJson() => {
        'type': type,
        'description': description,
        if (entityId != null) 'entity_id': entityId,
      };

  factory ResponseClaim.fromJson(Map<String, Object?> json) => ResponseClaim(
        type: (json['type'] as String? ?? 'unknown').trim(),
        description: json['description'] as String? ?? '',
        entityId: json['entity_id'] as String?,
      );
}

/// Structured final output produced by the synthesis (and repair) calls.
///
/// The model returns `{"message": ..., "included_outputs": [...],
/// "claims": [...], "includes_failure_report": ...}` so completeness and
/// truthfulness are validated from declared structure instead of inferred
/// by searching prose. Only [message] is rendered to the user.
class SynthesizedResponse {
  const SynthesizedResponse({
    required this.message,
    required this.includedOutputs,
    this.claims = const [],
    this.includesFailureReport = false,
  });

  final String message;
  final Set<ResponseOutputType> includedOutputs;

  /// Success claims the message makes, for evidence checking.
  final List<ResponseClaim> claims;

  /// True when the message discloses failed or skipped actions.
  final bool includesFailureReport;

  Map<String, Object?> toJson() => {
        'message': message,
        'included_outputs': includedOutputs.map((o) => o.wireName).toList(),
        'claims': [for (final claim in claims) claim.toJson()],
        'includes_failure_report': includesFailureReport,
      };

  /// The same response with corrected text - used when a measurable
  /// behavior rule (bullet count, no tables) was fixed in code, which keeps
  /// the declared outputs and claims intact.
  SynthesizedResponse withMessage(String newMessage) => SynthesizedResponse(
        message: newMessage,
        includedOutputs: includedOutputs,
        claims: claims,
        includesFailureReport: includesFailureReport,
      );

  /// The same response, also credited with [outputs].
  ///
  /// For a repair. It is asked to correct a message and to say again which
  /// required parts the message covers, and a small model does the first
  /// and not the second: in ten measured repairs the list came back empty
  /// or partial every time, so a message corrected exactly as asked was
  /// recorded as now missing the parts it had covered all along.
  SynthesizedResponse coveringAlso(Set<ResponseOutputType> outputs) =>
      SynthesizedResponse(
        message: message,
        includedOutputs: {...includedOutputs, ...outputs},
        claims: claims,
        includesFailureReport: includesFailureReport,
      );

  /// Parses the model's reply. Tolerates prose or ```json fences around the
  /// object, and repairs the one malformation small models produce
  /// constantly - raw newlines inside the `"message"` string. If nothing
  /// parses, the message is salvaged textually so a broken envelope is never
  /// shown to the user as raw JSON; only if that fails too does the whole
  /// text become the message (validation then decides about repair).
  factory SynthesizedResponse.parse(String text) {
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start >= 0 && end > start) {
      final slice = text.substring(start, end + 1);
      for (final candidate in [slice, _escapeControlCharsInStrings(slice)]) {
        final parsed = _tryDecode(candidate);
        if (parsed != null) return parsed;
      }
    }
    // Salvage reads the whole reply, not the braced slice: an envelope that
    // was cut off mid-generation has no closing brace to slice to, and that
    // is exactly when salvaging matters most.
    final salvaged = _salvageMessage(text);
    if (salvaged != null) {
      return SynthesizedResponse(
        message: salvaged,
        includedOutputs: const {},
      );
    }
    return SynthesizedResponse(
      message: text.trim(),
      includedOutputs: const {},
    );
  }

  static SynthesizedResponse? _tryDecode(String source) {
    try {
      final decoded = jsonDecode(source);
      if (decoded is Map) {
          final message = decoded['message'];
          if (message is String && message.trim().isNotEmpty) {
            final declared = decoded['included_outputs'];
            final outputs = <ResponseOutputType>{};
            if (declared is List) {
              for (final name in declared.whereType<String>()) {
                final type = ResponseOutputType.fromWireName(name);
                if (type != null) outputs.add(type);
              }
            }
            final claims = <ResponseClaim>[];
            if (decoded['claims'] is List) {
              for (final raw in (decoded['claims'] as List).whereType<Map>()) {
                final claim =
                    ResponseClaim.fromJson(raw.cast<String, Object?>());
                if (claim.type.isNotEmpty) claims.add(claim);
              }
            }
            return SynthesizedResponse(
              message: message.trim(),
              includedOutputs: outputs,
              claims: claims,
              includesFailureReport:
                  decoded['includes_failure_report'] == true ||
                      outputs.contains(ResponseOutputType.failureReport),
            );
          }
        }
    } catch (_) {
      // Caller tries the next repair strategy.
    }
    return null;
  }

  /// Escapes raw control characters that appear *inside* JSON string
  /// literals.
  ///
  /// RFC 8259 forbids unescaped U+0000-U+001F in strings, but smaller models
  /// routinely write the final message with real newlines in it. That single
  /// defect made `jsonDecode` throw and dumped the entire envelope into the
  /// chat as raw JSON. Outside string literals those same characters are
  /// legal whitespace, so tracking quote state is enough to repair it.
  static String _escapeControlCharsInStrings(String source) {
    final out = StringBuffer();
    var inString = false;
    var escaped = false;
    for (final rune in source.runes) {
      final char = String.fromCharCode(rune);
      if (escaped) {
        out.write(char);
        escaped = false;
        continue;
      }
      if (char == r'\') {
        out.write(char);
        escaped = true;
        continue;
      }
      if (char == '"') {
        inString = !inString;
        out.write(char);
        continue;
      }
      if (inString && rune <= 0x1f) {
        out.write(switch (rune) {
          0x08 => r'\b',
          0x09 => r'\t',
          0x0a => r'\n',
          0x0c => r'\f',
          0x0d => r'\r',
          _ => '\\u${rune.toRadixString(16).padLeft(4, '0')}',
        });
        continue;
      }
      out.write(char);
    }
    return out.toString();
  }

  /// Lifts just the `message` value out of an envelope that will not parse at
  /// all, so the user sees prose rather than JSON scaffolding. The value ends
  /// at the quote followed by a comma and one of the envelope's other keys
  /// (or the closing brace) - scanning for the first bare quote would cut the
  /// message off at its own punctuation.
  static String? _salvageMessage(String source) {
    final key = RegExp(r'"message"\s*:\s*"').firstMatch(source);
    if (key == null) return null;
    final terminator = RegExp(
      r'"\s*(?:,\s*"(?:included_outputs|claims|includes_failure_report)"'
      r'|\}\s*$)',
    ).firstMatch(source.substring(key.end));
    if (terminator == null) return null;
    final raw = source.substring(key.end, key.end + terminator.start);
    final out = StringBuffer();
    var escaped = false;
    for (final char in raw.split('')) {
      if (escaped) {
        out.write(switch (char) {
          'n' => '\n',
          't' => '\t',
          'r' => '\r',
          _ => char,
        });
        escaped = false;
        continue;
      }
      if (char == r'\') {
        escaped = true;
        continue;
      }
      out.write(char);
    }
    final message = out.toString().trim();
    return message.isEmpty ? null : message;
  }
}
