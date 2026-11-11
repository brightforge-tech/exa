import '../memory/models/agent_memory.dart';
import 'models/workflow_skill.dart';
import 'workflow_skill_repository.dart';

/// Deterministic skill matching, layered by trust:
///
///   1. Explicit user command ("run the daily briefing skill")
///   2. Exact trigger-phrase match
///   3. Router-nominated skill (validated against the registry)
///   4. Token similarity against name/description/triggers
///   5. Procedural memory that names the skill
///
/// Thresholds (spec §9.7): >= 0.80 use the skill automatically;
/// 0.60-0.79 guided assistance only; below 0.60 no skill.
class SkillMatcher {
  SkillMatcher(this._repository);

  final WorkflowSkillRepository _repository;

  static const double autoThreshold = 0.80;
  static const double assistThreshold = 0.60;

  Future<SkillMatch?> match({
    required String userRequest,
    Set<String> domains = const {},
    List<AgentMemory> proceduralMemories = const [],
    String? routerSkillName,
    double routerConfidence = 0,
  }) async {
    final skills = await _repository.listEnabled();
    if (skills.isEmpty) return null;

    final normalized = _normalize(userRequest);
    SkillMatch? best;

    void consider(SkillMatch candidate) {
      if (best == null || candidate.confidence > best!.confidence) {
        best = candidate;
      }
    }

    for (final skill in skills) {
      // 1. Explicit command naming the skill.
      final spokenName = skill.name.replaceAll('_', ' ');
      if (normalized.contains('run the $spokenName') ||
          normalized.contains('run $spokenName') ||
          normalized.contains('use the $spokenName')) {
        consider(SkillMatch(
            skill: skill, confidence: 0.98, matchSource: 'explicit_command'));
        continue;
      }

      // 2. Exact trigger phrase containment.
      for (final trigger in skill.triggerExamples) {
        final normalizedTrigger = _normalize(trigger);
        if (normalized == normalizedTrigger ||
            normalized.contains(normalizedTrigger)) {
          consider(SkillMatch(
              skill: skill, confidence: 0.92, matchSource: 'trigger'));
          break;
        }
      }

      // 4. Token similarity (best trigger wins; name/description add base).
      final requestTokens = _tokens(normalized);
      var similarity = 0.0;
      for (final trigger in skill.triggerExamples) {
        similarity = _max(similarity, _overlap(requestTokens, _tokens(trigger)));
      }
      similarity = _max(
          similarity,
          0.85 *
              _overlap(requestTokens,
                  _tokens('${skill.name.replaceAll('_', ' ')} ${skill.description}')));
      // Domain agreement nudges, never decides.
      if (similarity > 0 &&
          domains.isNotEmpty &&
          skill.requiredDomains.intersection(domains).isNotEmpty) {
        similarity += 0.05;
      }
      if (similarity >= 0.5) {
        consider(SkillMatch(
            skill: skill,
            confidence: similarity.clamp(0.0, 0.88),
            matchSource: 'similarity'));
      }

      // 5. Procedural memory that names this skill.
      for (final memory in proceduralMemories) {
        if (_normalize(memory.content).contains(spokenName)) {
          consider(SkillMatch(
              skill: skill,
              confidence: 0.7 * memory.confidence + 0.15,
              matchSource: 'procedural_memory'));
          break;
        }
      }
    }

    // 3. Router nomination - validated, capped, and only trusted when the
    // registry actually has the skill.
    if (routerSkillName != null && routerConfidence > 0) {
      final skill = skills
          .where((candidate) => candidate.name == routerSkillName)
          .firstOrNull;
      if (skill != null) {
        consider(SkillMatch(
          skill: skill,
          confidence: (routerConfidence * 0.9).clamp(0.0, 0.9),
          matchSource: 'router',
        ));
      }
    }

    final result = best;
    if (result == null || result.confidence < assistThreshold) return null;
    return result;
  }

  static double _max(double a, double b) => a > b ? a : b;

  /// Directional overlap: how much of the trigger's meaning the request
  /// covers.
  static double _overlap(Set<String> request, Set<String> trigger) {
    if (request.isEmpty || trigger.isEmpty) return 0;
    return trigger.intersection(request).length / trigger.length;
  }

  static String _normalize(String text) =>
      text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\s]'), ' ').trim();

  static Set<String> _tokens(String text) {
    const stopwords = {
      'the', 'a', 'an', 'and', 'or', 'my', 'me', 'i', 'am', 'is', 'are',
      'please', 'can', 'you', 'to', 'for', 'of', 'on', 'in', 'give',
    };
    return _normalize(text)
        .split(RegExp(r'\s+'))
        .where((token) => token.length > 1 && !stopwords.contains(token))
        .toSet();
  }
}
