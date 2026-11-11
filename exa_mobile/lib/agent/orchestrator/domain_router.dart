import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../services/ai_client/ai_client.dart';
import '../../services/ai_client/local_endpoint_client.dart';
import '../../services/ai_client/on_device_client.dart';
import '../../services/ai_client/openai_compatible_client.dart';
import '../models/agent_ids.dart';
import '../models/turn_contract.dart';
import '../tools/tool_domains.dart';

/// Structured context the router sees, so follow-ups like "now delete it"
/// resolve against what the previous turn touched instead of raw chat lines.
class RoutingContext {
  const RoutingContext({
    required this.currentMessage,
    this.previousUserMessage,
    this.previousDomains = const {},
    this.previousToolsUsed = const [],
    this.activeEntities = const {},
    this.activeEntitySummaries = const [],
    this.knownSkills = const [],
    this.lexicon = const [],
  });

  final String currentMessage;
  final String? previousUserMessage;
  final Set<String> previousDomains;
  final List<String> previousToolsUsed;

  /// Entity ids the previous turn worked with, keyed by kind
  /// (e.g. {"reminder_id": "reminder_284"}).
  final Map<String, String> activeEntities;

  /// Salience-ordered summaries from the active entity context, e.g.
  /// `{"type": "task", "name": "Send invoice", "id": "task_12",
  ///   "position": 2}` - lets the router resolve "the second one".
  final List<Map<String, Object?>> activeEntitySummaries;

  /// Workflow skill names the matcher knows, so the router can nominate one.
  final List<String> knownSkills;

  /// Names the user's requests are likely to use, so a proper noun the router
  /// has never seen is recognizable as a thing rather than routed on the
  /// surrounding verbs alone. Names only - see [RequestLexicon].
  final List<String> lexicon;

  Map<String, Object?> toJson() => {
        'current_message': currentMessage,
        if (previousUserMessage != null)
          'previous_user_message': previousUserMessage,
        if (previousDomains.isNotEmpty)
          'previous_domains': previousDomains.toList(),
        if (previousToolsUsed.isNotEmpty)
          'previous_tools_used': previousToolsUsed,
        if (activeEntities.isNotEmpty) 'active_entities': activeEntities,
        if (activeEntitySummaries.isNotEmpty)
          'recent_entities': activeEntitySummaries,
      };
}

/// The router's structured answer: not just which tool domains the request
/// needs, but what it must do, what the user expects back, and whether the
/// turn needs confirmation, verification, or a final synthesis call - all
/// from the same single stage-one request (no extra model round trip).
class DomainRoutingResult {
  const DomainRoutingResult({
    required this.domains,
    required this.actions,
    required this.responseOutputs,
    required this.requiresConfirmation,
    required this.requiresSynthesis,
    this.requiresVerification = false,
    this.constraints = const [],
    this.assumptions = const [],
    this.skillName,
    this.skillConfidence = 0,
    this.structured = true,
    this.primaryGoal,
    this.risk,
    this.requiredTools = const {},
  });

  /// Null means expose all tools (the router asked for everything).
  final Set<String>? domains;
  final List<ContractAction> actions;
  final Set<ResponseOutputType> responseOutputs;
  final bool requiresConfirmation;
  final bool requiresSynthesis;
  final bool requiresVerification;
  final List<String> constraints;
  final List<String> assumptions;

  /// Workflow skill the router nominated, if any (validated downstream by
  /// the deterministic skill matcher - never trusted blindly).
  final String? skillName;
  final double skillConfidence;

  /// False when this result was salvaged from a legacy bare-array reply and
  /// the contract fields are conservative defaults rather than routed values.
  final bool structured;

  /// One line stating what the user actually wants, used as the
  /// [TurnFrame]'s primary goal. Optional: a model that omits it gets a
  /// deterministic goal derived from the request instead.
  final String? primaryGoal;

  /// The router's own read of how consequential the turn is
  /// (`low` / `moderate` / `high`). It can only *raise* the deterministic
  /// assessment — a model under-reporting risk must not unlock a cheaper
  /// path.
  final String? risk;

  /// The exact tools the request needs, chosen from the compact capability
  /// catalogue. Only these get their full schema sent, which is a much
  /// bigger saving than sending whole domains. Empty means "no opinion" and
  /// the caller falls back to domain scoping — a router that names nothing
  /// must never leave the turn with no tools.
  final Set<String> requiredTools;
}

/// Stage 1 of the two-stage tool process: a small, fast model call that maps
/// the user's request to the tool domains it needs AND extracts the turn
/// contract (actions, required user-facing outputs, constraints,
/// confirmation/synthesis/verification flags, optional skill nomination).
///
/// Routing is strictly best-effort: any failure (network error, unparseable
/// reply, timeout) returns null and the caller falls back to sending every
/// tool with a conservative contract — never a worse outcome than before
/// scoping existed.
class DomainRouter {
  const DomainRouter();

  /// A slow routing call must not make the chat feel stuck; past this the
  /// caller just sends all tools.
  static const timeout = Duration(seconds: 20);

  /// The generous variant for local and on-device backends, where the same
  /// small JSON reply can legitimately take minutes and where a routed turn
  /// matters most: their context windows are too small for the full-registry
  /// fallback, so waiting longer is cheaper than falling back.
  static const slowProviderTimeout = Duration(minutes: 3);

  static const _system =
      "You analyze requests inside a personal assistant app. You reply with "
      'ONLY valid JSON — no prose, no explanation.';

  /// Worked examples, most valuable first.
  ///
  /// This call is where the request is actually interpreted, and it was
  /// zero-shot: the schema was described but never demonstrated. Workflow
  /// skills carry `triggerExamples` and the matcher uses them; the stage that
  /// does the harder job had nothing. Small models are much better at copying
  /// a shape than at inferring one from prose, and `required_tools` accuracy is
  /// what makes exact-tool loading pay at all - a wrong list costs the saving
  /// *and* an `expand_tools` round trip.
  ///
  /// Ordered so that trimming from the end drops the least important first.
  /// Each covers one observed failure:
  ///   1. two asks collapsed into one action;
  ///   2. a pronoun follow-up not resolved against the entity context;
  ///   3. "show me" answered by listing in chat instead of opening a screen;
  ///   4. "build me an app" routed to files/chat instead of the UI builder
  ///      (its data goes in a collection, not the task list);
  ///   5. a digest routed without the outputs it owes.
  static const _examples = <String>[
    '''
Request: "Create a task to chase the Acme invoice and email Dana about it"
{"primary_goal": "Create a chase task and email Dana",
 "domains": ["tasks", "email"],
 "required_tools": ["create_task", "send_email"],
 "actions": [{"description": "create_task", "required": true},
             {"description": "send_email", "required": true}],
 "response_outputs": ["confirmation"],
 "constraints": [], "skill": null, "skill_confidence": 0,
 "risk": "high", "requires_confirmation": true,
 "requires_synthesis": true, "requires_verification": true}''',
    '''
Request: "now cancel it"  - recent entities include a reminder named "Stretch" with id reminder_284, so "it" is that reminder
{"primary_goal": "Cancel the Stretch reminder",
 "domains": ["reminders"],
 "required_tools": ["cancel_reminder"],
 "actions": [{"description": "cancel_reminder", "required": true}],
 "response_outputs": ["confirmation"],
 "constraints": [], "skill": null, "skill_confidence": 0,
 "risk": "high", "requires_confirmation": false,
 "requires_synthesis": false, "requires_verification": false}''',
    '''
Request: "show me this week's schedule"
{"primary_goal": "Open the schedule for this week",
 "domains": ["core"],
 "required_tools": ["open_screen"],
 "actions": [{"description": "open_screen", "required": true}],
 "response_outputs": ["confirmation"],
 "constraints": [], "skill": null, "skill_confidence": 0,
 "risk": "low", "requires_confirmation": false,
 "requires_synthesis": false, "requires_verification": false}''',
    '''
Request: "build me a note taking app"
{"primary_goal": "Build a complete note-taking feature",
 "domains": ["dynamic_ui"],
 "required_tools": ["list_collections", "define_collection",
                    "create_dynamic_screen"],
 "actions": [{"description": "define_collection", "required": true},
             {"description": "create_dynamic_screen", "required": true}],
 "response_outputs": ["confirmation"],
 "constraints": [], "skill": null, "skill_confidence": 0,
 "risk": "low", "requires_confirmation": false,
 "requires_synthesis": false, "requires_verification": true}''',
    '''
Request: "go through my new email and pull out anything I need to do"
{"primary_goal": "Digest new email and extract actions",
 "domains": ["email", "tasks"],
 "required_tools": ["sync_emails", "read_email_context", "create_task",
                    "mark_email_digested"],
 "actions": [{"description": "read_email_context", "required": true},
             {"description": "create_task", "required": true},
             {"description": "mark_email_digested", "required": true}],
 "response_outputs": ["rundown", "task_list", "deadline_list",
                      "attention_items"],
 "constraints": [], "skill": null, "skill_confidence": 0,
 "risk": "high", "requires_confirmation": false,
 "requires_synthesis": true, "requires_verification": true}''',
  ];

  /// How many examples a model with [contextWindow] tokens can afford.
  ///
  /// The examples cost roughly 200 tokens each, and they compete with the
  /// capability catalogue - which on a very small model is the thing that
  /// keeps the *action* call affordable, so it wins. Above a comfortable
  /// window they are nearly free, and on the remote provider they are static
  /// text sitting in a cacheable prefix.
  /// One example's text, so a test can assert the parser accepts what the
  /// prompt teaches. An example this code could not parse would be teaching
  /// the model a shape it rejects.
  @visibleForTesting
  static String exampleAt(int index) => _examples[index];

  @visibleForTesting
  static int exampleCountFor(int? contextWindow) {
    final window = contextWindow ?? 32768;
    if (window >= 16000) return _examples.length;
    if (window >= 8000) return 2;
    return 0;
  }

  /// Routes [context.currentMessage]. Returns null when routing fails
  /// entirely (caller sends all tools and uses the fallback contract).
  Future<DomainRoutingResult?> route({
    required AiClient client,
    String? apiKey,
    required String model,
    required RoutingContext context,
    List<Map<String, String>> toolCatalog = const [],
  }) async =>
      (await routeWithReply(
        client: client,
        apiKey: apiKey,
        model: model,
        context: context,
        toolCatalog: toolCatalog,
      ))
          .result;

  /// [route], with the model's reply kept beside the result so a route that
  /// will be asked for again can be stored (see `RouteCache`).
  ///
  /// [roomToThink] is for the caller about to store the result: the reply
  /// then pays for itself on every later run, so a model that insists on
  /// deliberating is given the room to finish once rather than being cut
  /// off at the same place every time.
  Future<({DomainRoutingResult? result, String? reply})> routeWithReply({
    required AiClient client,
    String? apiKey,
    required String model,
    required RoutingContext context,
    List<Map<String, String>> toolCatalog = const [],
    bool roomToThink = false,
  }) async {
    final prompt = StringBuffer()
      ..writeln("Analyze the user's request and return only valid JSON.")
      ..writeln('Identify:')
      ..writeln('1. The tool domains required.')
      ..writeln('2. The actions Exa must perform, and whether each is '
          'required or optional.')
      ..writeln('3. The user-facing outputs Exa must return.')
      ..writeln('4. Constraints the request imposes (things Exa must NOT '
          'do, or limits to respect).')
      ..writeln('5. Whether confirmation is required before consequential '
          'actions.')
      ..writeln('6. Whether a final response-synthesis step is required.')
      ..writeln('7. Whether the finished turn should be verified '
          '(multi-step, multi-domain, or consequential requests).')
      ..writeln()
      ..writeln('Actions describe things Exa must do through tools, as short '
          'labels (e.g. "review_emails", "create_tasks").')
      ..writeln('Response outputs describe things the user expects Exa to '
          'say, show, summarize, list, explain, recommend, compare, confirm, '
          'or report.')
      ..writeln('Completing tool actions does not automatically satisfy '
          'response outputs.')
      ..writeln('Set requires_synthesis true whenever the user asked for any '
          'summary, rundown, explanation, recommendation, comparison, plan, '
          'or report, or the request needs several actions; single-step '
          'navigation ("open my tasks") does not need it.')
      ..writeln()
      ..writeln('Allowed domains:')
      ..writeln('- core (navigation/search only)')
      ..writeln(ToolDomains.selectable.entries
          .map((e) => '- ${e.key} (${e.value})')
          .join('\n'))
      ..writeln('- all (unsure, or the request is very broad)')
      ..writeln()
      ..writeln('Allowed response outputs:')
      ..writeln(ResponseOutputType.allWireNames
          .map((name) => '- $name')
          .join('\n'))
      ..writeln();
    if (toolCatalog.isNotEmpty) {
      // The catalogue is one line per tool (~450 tokens for all 46) versus
      // ~6,700 for their real schemas. Naming the handful actually needed
      // here is what keeps the action call affordable on a small model.
      prompt
        ..writeln('Available tools (name: purpose). List in '
            '"required_tools" ONLY the ones this request needs - be exact '
            'and be complete; a tool you leave out is one you will not '
            'have:')
        ..writeln(toolCatalog
            .map((tool) => '- ${tool['name']}: ${tool['purpose']}')
            .join('\n'))
        ..writeln();
    }
    if (context.knownSkills.isNotEmpty) {
      prompt
        ..writeln('Known workflow skills (set "skill" to one ONLY when the '
            'request clearly matches it, with your confidence 0-1):')
        ..writeln(context.knownSkills.map((name) => '- $name').join('\n'))
        ..writeln();
    }
    if (context.lexicon.isNotEmpty) {
      prompt
        ..writeln('Things the user has referred to before. These are names '
            'only - use them to recognize what the request is about, never as '
            'facts and never as the answer:')
        ..writeln(context.lexicon.map((line) => '- $line').join('\n'))
        ..writeln();
    }
    final contextJson = context.toJson()..remove('current_message');
    if (contextJson.isNotEmpty) {
      prompt
        ..writeln('Conversation context (for follow-ups like "delete it"):')
        ..writeln(jsonEncode(contextJson))
        ..writeln();
    }
    prompt
      ..writeln("The user's request:")
      ..writeln(context.currentMessage)
      ..writeln()
      ..writeln('Return this exact structure:')
      ..writeln('{')
      ..writeln('  "primary_goal": "<one line: what the user wants>",')
      ..writeln('  "domains": [],')
      ..writeln('  "required_tools": [],')
      ..writeln('  "actions": [{"description": "", "required": true}],')
      ..writeln('  "response_outputs": [],')
      ..writeln('  "constraints": [],')
      ..writeln('  "skill": null,')
      ..writeln('  "skill_confidence": 0,')
      ..writeln('  "risk": "low",')
      ..writeln('  "requires_confirmation": false,')
      ..writeln('  "requires_synthesis": false,')
      ..writeln('  "requires_verification": false')
      ..writeln('}')
      ..writeln('"risk" is "high" when the request sends, deletes, spends, '
          'or is otherwise hard to undo; "moderate" for multi-step work; '
          'otherwise "low".');

    // Examples last: they are the most recent thing the model reads before
    // answering, and the shape it copies should be the shape it just saw.
    final exampleCount = exampleCountFor(client.contextWindow);
    if (exampleCount > 0) {
      prompt
        ..writeln()
        ..writeln('Worked examples. Note that a request with two asks gets '
            'TWO actions, and every tool needed appears in '
            '"required_tools":')
        ..writeln(_examples.take(exampleCount).join('\n'));
    }

    final routeTimeout =
        client is LocalEndpointClient || client is OnDeviceClient
            ? slowProviderTimeout
            : timeout;
    // The answer is a small JSON object; headroom for adaptive thinking on
    // providers that spend some.
    final maxTokens = roomToThink
        ? 1024 + OpenAiCompatibleClient.headroomOf(client)
        : 1024;
    final messages = [
      {'role': 'user', 'content': prompt.toString()},
    ];
    try {
      // A fixed-shape answer needs no deliberation, and on a local
      // reasoning model the deliberation was all the call ever produced.
      final request = client is OpenAiCompatibleClient
          ? client.createMessage(
              apiKey: apiKey,
              model: model,
              system: _system,
              messages: messages,
              maxTokens: maxTokens,
              deliberate: false,
            )
          : client.createMessage(
              apiKey: apiKey,
              model: model,
              system: _system,
              messages: messages,
              maxTokens: maxTokens,
            );
      final response = await request.timeout(
          roomToThink && routeTimeout < slowProviderTimeout * 2
              ? routeTimeout * 2
              : routeTimeout);
      final reply = response.text;
      return (result: parseRoutingResult(reply), reply: reply);
    } catch (_) {
      return (result: null, reply: null);
    }
  }

  /// Extracts the structured routing result. Tolerates prose around the
  /// JSON. Unknown domains and unknown response-output values are dropped;
  /// action entries may be objects or plain strings; a legacy bare-array
  /// reply degrades to a conservative result; anything unparseable returns
  /// null (= all tools + fallback contract).
  static DomainRoutingResult? parseRoutingResult(String text) {
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start >= 0 && end > start) {
      Object? decoded;
      try {
        decoded = jsonDecode(text.substring(start, end + 1));
      } catch (_) {
        decoded = null;
      }
      if (decoded is Map) {
        final domains = _parseDomainNames(decoded['domains']);
        final actions = _parseActions(decoded['actions']);
        final outputs = <ResponseOutputType>{};
        if (decoded['response_outputs'] is List) {
          for (final name
              in (decoded['response_outputs'] as List).whereType<String>()) {
            final type = ResponseOutputType.fromWireName(name);
            if (type != null) outputs.add(type);
          }
        }
        final skillRaw = decoded['skill'];
        final confidenceRaw = decoded['skill_confidence'];
        final goalRaw = decoded['primary_goal'];
        final riskRaw = decoded['risk'];
        return DomainRoutingResult(
          requiredTools: ((decoded['required_tools'] as List?) ?? const [])
              .whereType<String>()
              .map((name) => name.trim())
              .where((name) => name.isNotEmpty)
              .toSet(),
          primaryGoal: goalRaw is String && goalRaw.trim().isNotEmpty
              ? goalRaw.trim()
              : null,
          risk: riskRaw is String && riskRaw.trim().isNotEmpty
              ? riskRaw.trim().toLowerCase()
              : null,
          domains: domains,
          actions: actions,
          responseOutputs: outputs,
          constraints: ((decoded['constraints'] as List?) ?? const [])
              .whereType<String>()
              .toList(),
          assumptions: ((decoded['assumptions'] as List?) ?? const [])
              .whereType<String>()
              .toList(),
          skillName: skillRaw is String && skillRaw.trim().isNotEmpty
              ? skillRaw.trim()
              : null,
          skillConfidence:
              confidenceRaw is num ? confidenceRaw.toDouble().clamp(0, 1) : 0,
          requiresConfirmation: decoded['requires_confirmation'] == true,
          requiresSynthesis: decoded['requires_synthesis'] == true,
          requiresVerification: decoded['requires_verification'] == true,
        );
      }
    }
    // Legacy shape: a bare domain array. Keep the domains, but the contract
    // is conservative (a useful confirmation, via synthesis) because the
    // reply carried no output information.
    final legacyDomains = parseDomains(text);
    if (legacyDomains != null) {
      return DomainRoutingResult(
        domains: legacyDomains,
        actions: const [],
        responseOutputs: const {ResponseOutputType.confirmation},
        requiresConfirmation: false,
        requiresSynthesis: true,
        requiresVerification: false,
        structured: false,
      );
    }
    return null;
  }

  /// Action entries arrive either as `{"description": ..., "required": ...}`
  /// objects (current prompt) or plain strings (smaller models, older
  /// prompts). Both become [ContractAction]s; strings default to required.
  static List<ContractAction> _parseActions(Object? raw) {
    if (raw is! List) return const [];
    final actions = <ContractAction>[];
    for (final entry in raw) {
      if (entry is String && entry.trim().isNotEmpty) {
        actions.add(ContractAction(
          id: AgentId.contractAction(),
          description: entry.trim(),
        ));
      } else if (entry is Map) {
        final description = entry['description'];
        if (description is String && description.trim().isNotEmpty) {
          actions.add(ContractAction(
            id: AgentId.contractAction(),
            description: description.trim(),
            required: entry['required'] != false,
            expectedToolNames:
                ((entry['expected_tools'] as List?) ?? const [])
                    .whereType<String>()
                    .toList(),
          ));
        }
      }
    }
    return actions;
  }

  /// Parses the "domains" field. Null = all tools (missing, invalid, "all",
  /// or nothing recognizable).
  static Set<String>? _parseDomainNames(Object? raw) {
    if (raw is! List) return null;
    final names = raw
        .whereType<String>()
        .map((name) => name.trim().toLowerCase())
        .toSet();
    if (names.contains('all')) return null;
    final known = names
        .where((name) =>
            name == ToolDomains.core ||
            ToolDomains.selectable.containsKey(name))
        .toSet();
    // Some names but none recognized = the router hallucinated; distrust it.
    if (names.isNotEmpty && known.isEmpty) return null;
    return known;
  }

  /// Extracts a domain set from a bare-array reply. Tolerates prose around
  /// the array. Returns null (= use all tools) for `["all"]`, no array, bad
  /// JSON, or an array of only unknown names; returns the empty set only for
  /// a deliberate `[]`.
  @visibleForTesting
  static Set<String>? parseDomains(String text) {
    final start = text.indexOf('[');
    final end = text.lastIndexOf(']');
    if (start < 0 || end <= start) return null;
    final List<dynamic> decoded;
    try {
      decoded = jsonDecode(text.substring(start, end + 1)) as List;
    } catch (_) {
      return null;
    }
    final names = decoded
        .whereType<String>()
        .map((name) => name.trim().toLowerCase())
        .toSet();
    if (names.contains('all')) return null;
    final known = names
        .where((name) =>
            name == ToolDomains.core ||
            ToolDomains.selectable.containsKey(name))
        .toSet();
    if (names.isNotEmpty && known.isEmpty) return null;
    return known;
  }
}
