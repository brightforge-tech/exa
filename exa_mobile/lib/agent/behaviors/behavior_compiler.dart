import '../../data/models/agent_behavior.dart';
import '../../data/repositories/behavior_repository.dart';
import 'behavior_context.dart';
import 'behavior_plan.dart';

/// Compiles (and caches) the behaviour plan for a turn.
///
/// Resolution is pure given the active rules, so the expensive part - the
/// database read plus filtering, conflict resolution and rendering - is
/// cached per distinct request shape. The cache key includes the behavior
/// table's version, so any write invalidates every entry without needing
/// targeted eviction.
///
/// The rendered blocks are deliberately stable and ordered: local models
/// reuse a prompt prefix across calls only when the bytes match, so nothing
/// variable (timestamps, ids, random ordering) goes into a block.
class BehaviorCompiler {
  BehaviorCompiler(this._behaviors);

  final BehaviorRepository _behaviors;

  final Map<String, BehaviorPlan> _cache = {};
  List<AgentBehavior>? _activeCache;
  int? _activeCacheVersion;

  static const maxCacheEntries = 32;

  /// Compiles the plan for one turn. Never throws: a behaviour lookup
  /// failing must not take down the turn that wanted it.
  Future<BehaviorPlan> compile({
    Set<String>? domains,
    String surface = BehaviorSurface.chat,
    bool unattended = false,
    int? contextWindow,
    String intent = '',
    List<AgentBehavior>? snapshot,
  }) async {
    try {
      final version = snapshot != null
          ? -1
          : await _behaviors.currentVersion();
      final key = _key(
        version: version,
        surface: surface,
        domains: domains,
        unattended: unattended,
        contextWindow: contextWindow,
        intent: intent,
      );
      if (snapshot == null) {
        final hit = _cache[key];
        if (hit != null) return hit;
      }

      final active = snapshot ?? await _loadActive(version);
      final plan = BehaviorPlan.compile(
        active,
        domains: domains,
        surface: surface,
        unattended: unattended,
        contextWindow: contextWindow,
        version: version,
      );
      if (snapshot == null) {
        if (_cache.length >= maxCacheEntries) _cache.clear();
        _cache[key] = plan;
      }
      return plan;
    } catch (_) {
      return BehaviorPlan.empty;
    }
  }

  Future<List<AgentBehavior>> _loadActive(int version) async {
    if (_activeCacheVersion == version && _activeCache != null) {
      return _activeCache!;
    }
    final active = await _behaviors.listActive();
    _activeCache = active;
    _activeCacheVersion = version;
    return active;
  }

  /// Drops everything cached. Called after a behaviour write in the same
  /// isolate; other isolates notice via the version in the key.
  void invalidate() {
    _cache.clear();
    _activeCache = null;
    _activeCacheVersion = null;
  }

  static String _key({
    required int version,
    required String surface,
    required Set<String>? domains,
    required bool unattended,
    required int? contextWindow,
    required String intent,
  }) {
    final domainKey =
        domains == null ? 'all' : (domains.toList()..sort()).join('+');
    final mode = unattended ? 'unattended' : 'interactive';
    return 'v$version:$surface:$domainKey:$intent:$mode:'
        '${contextWindow ?? 'default'}';
  }
}
