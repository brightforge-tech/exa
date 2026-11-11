import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../data/repositories/settings_repository.dart';
import 'domain_router.dart';

/// What the cache holds for one request.
class CachedRoute {
  const CachedRoute._({this.routing, this.givenUp = false});

  /// The route to use. Null when there is none worth using.
  final DomainRoutingResult? routing;

  /// True when routing this request has failed often enough, recently
  /// enough, that asking again is not worth the call. The turn runs unrouted.
  final bool givenUp;
}

/// Remembers how a scheduled job's instructions were routed.
///
/// A recurring job sends the same request every run, and until now paid for
/// routing it every run. Two days of server logs put a number on that: the
/// routing call was 31% of all model time, and in 292 of 295 runs it was cut
/// off before it finished, so the time bought nothing. Routing the same text
/// twice should not happen once, let alone every ten minutes.
///
/// Keyed by what the router is actually shown - the request, the tools it
/// may choose from, the skills it may nominate - so editing a job's
/// instructions, or an app update that adds a tool, routes afresh. Only
/// isolated runs use it: a chat turn's route depends on the conversation it
/// sits in, and a cached one would answer a question nobody asked.
///
/// A route is remembered only once a run that followed it has done
/// everything it planned, and forgotten the first time one does not. The
/// router is a model and its plan varies: asked to "list my tasks, then
/// write a short list", one answer in a few plans a file to be written.
/// Remembered, that plan would be followed on every later run, each ending
/// with work reported as not done and the answer rewritten and repaired to
/// say so. A bad route costs one run this way, not all of them.
///
/// Kept in the settings table rather than on the job. It is derived, it can
/// be thrown away at any time, and a job whose route is missing simply
/// routes again.
class RouteCache {
  RouteCache(this._settings, {DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final SettingsRepository _settings;
  final DateTime Function() _now;

  /// Bumped when the routing prompt or reply format changes shape.
  static const version = 1;

  static const keyPrefix = 'route_cache.';

  /// Failures after which a request is left unrouted for [retryAfter].
  static const maxFailures = 2;

  /// A route that would not compute is tried again after this long: the
  /// model behind the endpoint may have been swapped for one that can.
  static const retryAfter = Duration(hours: 24);

  /// Distinct requests remembered. Jobs are few; this bounds the rest.
  static const maxEntries = 40;

  static String keyFor({
    required String request,
    required Iterable<String> toolNames,
    Iterable<String> skills = const [],
  }) {
    final tools = toolNames.toList()..sort();
    final known = skills.toList()..sort();
    final digest = sha1.convert(utf8.encode(
        'v$version\n${request.trim()}\n${tools.join(',')}\n${known.join(',')}'));
    return '$keyPrefix$digest';
  }

  Future<CachedRoute?> read(String key) async {
    final entry = _decode(await _settings.getValue(key));
    if (entry == null) return null;
    final reply = entry['reply'];
    if (reply is String && reply.isNotEmpty) {
      final routing = DomainRouter.parseRoutingResult(reply);
      // A stored reply that no longer parses is a miss, not an error.
      if (routing != null && routing.structured) {
        return CachedRoute._(routing: routing);
      }
      return null;
    }
    final failures = (entry['failures'] as num?)?.toInt() ?? 0;
    final at = DateTime.tryParse('${entry['at']}');
    if (failures >= maxFailures &&
        at != null &&
        _now().difference(at) < retryAfter) {
      return const CachedRoute._(givenUp: true);
    }
    return null;
  }

  Future<void> save(String key, String reply) async {
    await _settings.setValue(
        key,
        jsonEncode({
          'v': version,
          'reply': reply,
          'at': _now().toIso8601String(),
        }));
    await _prune();
  }

  /// Drops whatever is held for [key], so the next run routes afresh.
  Future<void> forget(String key) => _settings.removeValue(key);

  Future<void> recordFailure(String key) async {
    final entry = _decode(await _settings.getValue(key));
    final at = DateTime.tryParse('${entry?['at']}');
    // Failures from before the last retry window do not count against
    // this one.
    final stale = at == null || _now().difference(at) >= retryAfter;
    final failures =
        stale ? 0 : ((entry?['failures'] as num?)?.toInt() ?? 0);
    await _settings.setValue(
        key,
        jsonEncode({
          'v': version,
          'failures': failures + 1,
          'at': _now().toIso8601String(),
        }));
    await _prune();
  }

  Future<void> _prune() async {
    final keys = await _settings.keysWithPrefix(keyPrefix);
    if (keys.length <= maxEntries) return;
    final aged = <({String key, DateTime at})>[];
    for (final key in keys) {
      final entry = _decode(await _settings.getValue(key));
      aged.add((
        key: key,
        at: DateTime.tryParse('${entry?['at']}') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      ));
    }
    aged.sort((a, b) => a.at.compareTo(b.at));
    for (final old in aged.take(aged.length - maxEntries)) {
      await _settings.removeValue(old.key);
    }
  }

  static Map<String, Object?>? _decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final entry = decoded.cast<String, Object?>();
      return entry['v'] == version ? entry : null;
    } catch (_) {
      return null;
    }
  }
}
