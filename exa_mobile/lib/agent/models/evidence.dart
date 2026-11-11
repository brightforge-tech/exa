import 'dart:convert';
import 'dart:math' as math;

import '../memory/models/agent_memory.dart';
import '../security/content_trust.dart';
import '../services/context_budget.dart';
import 'tool_execution_record.dart';

/// One piece of evidence the turn may build its answer on.
///
/// Everything the model is allowed to state as fact comes through here, with
/// an id it can cite. That is what lets validation ask "which record says
/// so?" of a name, a date, or a count instead of trusting the sentence.
class Evidence {
  const Evidence({
    required this.evidenceId,
    required this.sourceType,
    required this.sourceId,
    required this.trust,
    required this.content,
    required this.updatedAt,
    this.confidence = 1.0,
    this.summary,
    this.payload,
  });

  /// Short, stable within a turn: `ev_1`, `ev_2`, ...
  final String evidenceId;

  /// `memory`, `tool_result`, `email`, `browser`, `file`, `task`, ...
  final String sourceType;
  final String sourceId;
  final ContentTrust trust;
  final String content;
  final DateTime updatedAt;
  final double confidence;
  final String? summary;

  /// The structured form of [content], when there is one. Kept so an
  /// oversized tool result can be shortened by dropping list items rather
  /// than by cutting its JSON in half.
  final Object? payload;

  bool get isMemory => sourceType == 'memory';

  Map<String, Object?> toJson() => {
        'evidence_id': evidenceId,
        'source_type': sourceType,
        'source_id': sourceId,
        'updated_at': updatedAt.toIso8601String(),
        'confidence': confidence,
        'trust': trust.wireName,
        if (summary != null) 'summary': summary,
        'content': content,
      };
}

/// The turn's evidence, assembled once and shared by the synthesizer, the
/// verifier and the replay trace.
class EvidenceLedger {
  EvidenceLedger();

  final List<Evidence> _items = [];
  var _nextId = 1;

  List<Evidence> get all => List.unmodifiable(_items);
  bool get isEmpty => _items.isEmpty;
  int get length => _items.length;

  Evidence? operator [](String evidenceId) {
    for (final item in _items) {
      if (item.evidenceId == evidenceId) return item;
    }
    return null;
  }

  Evidence add({
    required String sourceType,
    required String sourceId,
    required String content,
    required DateTime updatedAt,
    ContentTrust trust = ContentTrust.verifiedAppState,
    double confidence = 1.0,
    String? summary,
    Object? payload,
  }) {
    final evidence = Evidence(
      evidenceId: 'ev_${_nextId++}',
      sourceType: sourceType,
      sourceId: sourceId,
      trust: trust,
      content: content,
      updatedAt: updatedAt,
      confidence: confidence,
      summary: summary,
      payload: payload,
    );
    _items.add(evidence);
    return evidence;
  }

  /// Wraps a retrieved memory. Memories are supporting context, so they
  /// carry their own confidence rather than inheriting a tool result's.
  Evidence addMemory(AgentMemory memory) => add(
        sourceType: 'memory',
        sourceId: memory.id,
        content: memory.content,
        updatedAt: memory.updatedAt,
        trust: memory.provenance.isExplicit
            ? ContentTrust.userSavedRule
            : ContentTrust.generatedSummary,
        confidence: memory.confidence,
        summary: memory.kind.wireName,
      );

  /// Wraps a tool execution record. Content read from outside the app keeps
  /// the [ContentTrust.externalContent] label all the way through, so a
  /// claim sourced from an email body is distinguishable from one sourced
  /// from the task table.
  Evidence? addToolRecord(ToolExecutionRecord record) {
    if (record.isControlPlane) return null;
    if (record.status != ToolExecutionStatus.success) return null;
    final external = ExternalContentGuard.externalSourceFor(record.toolName);
    final encoded = _encode(record.rawResult);
    if (encoded.isEmpty) return null;
    return add(
      sourceType: external ?? 'tool_result',
      sourceId: record.toolCallId,
      content: encoded,
      updatedAt: record.completedAt,
      trust: external == null
          ? ContentTrust.verifiedAppState
          : ContentTrust.externalContent,
      summary: record.summary ?? record.toolName,
      payload: record.rawResult is Map || record.rawResult is List
          ? record.rawResult
          : null,
    );
  }

  /// The pack size used when the caller does not know the model's window.
  static const defaultPackChars = 6000;

  /// The most of a pack that memories may hold while tool results still
  /// want the room.
  static const memoryShare = 0.25;

  static const _memoryCapChars = 600;
  static const _floorChars = 120;

  /// The compact pack handed to the model: ids, provenance, and content,
  /// within [maxChars] (see [ContextBudget.evidenceChars]).
  ///
  /// What the turn just read is served first. The pack used to be split
  /// evenly, memories ahead of tool results, with no item above 2,000
  /// characters - so a morning summary that listed thirty tasks reached the
  /// model writing it as the first few, cut mid-object, and the reply said
  /// the names and times "aren't available to me". A result now gets what it
  /// needs while there is room, the room is shared by need rather than by
  /// count, and one that still does not fit loses list items, not syntax.
  String pack({int maxChars = defaultPackChars, int maxItems = 24}) {
    if (_items.isEmpty) return '';
    final selected = [
      for (final item in _items)
        if (!item.isMemory) item,
      for (final item in _items)
        if (item.isMemory) item,
    ].take(maxItems).toList();
    final shares = _shares(selected, maxChars);
    return jsonEncode([
      for (final item in selected)
        {
          'evidence_id': item.evidenceId,
          'source_type': item.sourceType,
          'trust': item.trust.wireName,
          if (item.confidence < 1) 'confidence': item.confidence,
          'content': _fitted(item, shares[item.evidenceId]!),
        },
    ]);
  }

  static int _need(Evidence item) => item.isMemory
      ? math.min(item.content.length, _memoryCapChars)
      : item.content.length;

  static Map<String, int> _shares(List<Evidence> selected, int maxChars) {
    final results = [
      for (final item in selected)
        if (!item.isMemory) item,
    ];
    final memories = [
      for (final item in selected)
        if (item.isMemory) item,
    ];
    final memoryNeed =
        memories.fold<int>(0, (sum, item) => sum + _need(item));
    final reserved =
        math.min(memoryNeed, (maxChars * memoryShare).floor());
    final shares = <String, int>{};
    _share(results, math.max(maxChars - reserved, 0), shares);
    final used =
        results.fold<int>(0, (sum, item) => sum + shares[item.evidenceId]!);
    // Whatever the results left over is the memories' too.
    _share(memories, math.max(maxChars - used, reserved), shares);
    return shares;
  }

  /// Smallest first: an item that needs less than an even share takes only
  /// what it needs, and the difference goes to the ones that need more.
  static void _share(
      List<Evidence> items, int budget, Map<String, int> shares) {
    final bySize = [...items]
      ..sort((a, b) => _need(a).compareTo(_need(b)));
    var remaining = budget;
    for (var i = 0; i < bySize.length; i++) {
      final even = remaining ~/ (bySize.length - i);
      final given =
          math.min(_need(bySize[i]), math.max(even, _floorChars));
      shares[bySize[i].evidenceId] = given;
      remaining = math.max(remaining - given, 0);
    }
  }

  /// Structured content goes in as JSON, not as a string of JSON: quoting it
  /// again costs a character per quote and hands a small model a wall of
  /// backslashes to read names out of.
  static Object _fitted(Evidence item, int share) {
    final payload = item.payload;
    if (item.content.length <= share) return payload ?? item.content;
    if (payload is Map) {
      final shortened = ToolResultBudget.fit(
          payload, ToolResultBudget.tokensForJsonChars(share));
      if (shortened != null && jsonEncode(shortened).length <= share) {
        return shortened;
      }
    }
    return '${item.content.substring(0, share)}…';
  }

  /// Every id in the ledger, so validation can reject a citation that does
  /// not exist.
  Set<String> get ids => {for (final item in _items) item.evidenceId};

  /// All evidence text as one searchable blob, used to check whether a
  /// name, date or number in the response appears anywhere in the turn's
  /// evidence at all.
  String get corpus => _items.map((item) => item.content).join('\n');

  bool get hasExternalContent =>
      _items.any((item) => item.trust == ContentTrust.externalContent);

  static String _encode(Object? value) {
    if (value == null) return '';
    if (value is String) return value;
    try {
      return jsonEncode(value);
    } catch (_) {
      return value.toString();
    }
  }
}
