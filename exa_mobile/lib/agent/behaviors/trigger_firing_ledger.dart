import 'package:sqflite/sqflite.dart'
    show ConflictAlgorithm, DatabaseException;

import '../../data/database/app_database.dart';
import '../models/agent_ids.dart';
import 'behavior_triggers.dart';

/// Why a trigger was not allowed to fire.
enum TriggerRefusal {
  alreadyFiredForEvent,
  dailyLimitReached,
  recursiveFiring,
}

/// Durable record of every behaviour-trigger firing.
///
/// The pacing interval lives in settings and survives restarts, which is
/// enough to stop a 2-minute sync starting a model turn every 2 minutes. It
/// is not enough for the rest: the same email arriving in two syncs can fire
/// the same rule twice, a rule firing every 30 minutes all day is 48 model
/// turns nobody asked for, and work created by a firing can raise the event
/// that fires it again.
///
/// One row per (behaviour, event) makes the first impossible via a unique
/// index, and the day counter makes the second enforceable across process
/// restarts — which matters because background isolates have no shared
/// memory to count in.
class TriggerFiringLedger {
  TriggerFiringLedger(this._database);

  final AppDatabase _database;

  /// Checks every safeguard and, when they all pass, claims the firing.
  ///
  /// Claiming and checking are one step on purpose: two isolates can reach
  /// this at the same moment, and the unique index is what actually decides
  /// between them.
  Future<TriggerRefusal?> claim({
    required BehaviorTrigger trigger,
    required String eventId,
    String? jobRunId,
    bool triggeredByTriggerWork = false,
  }) async {
    // Work produced by a trigger must never raise the event that fires the
    // same trigger. Nothing else in the system breaks that cycle.
    if (triggeredByTriggerWork) return TriggerRefusal.recursiveFiring;

    final today = _dayKey(DateTime.now());
    try {
      final firedToday = await _countForDay(trigger.behaviorId, today);
      if (firedToday >= trigger.maxFiringsPerDay) {
        return TriggerRefusal.dailyLimitReached;
      }
      await _database.db.insert(
        'behavior_trigger_firings',
        {
          'id': AgentId.turn(),
          'behavior_id': trigger.behaviorId,
          'event_id': eventId,
          'job_run_id': jobRunId,
          'effects_created': 0,
          'fired_on': today,
          'created_at': DateTime.now().toIso8601String(),
        },
        // The unique index on (behavior_id, event_id) is the lock. Losing
        // the insert means another isolate already claimed this event.
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
      return null;
    } on DatabaseException catch (e) {
      if (e.isUniqueConstraintError()) {
        return TriggerRefusal.alreadyFiredForEvent;
      }
      // Table missing on an un-migrated database: the interval pacing still
      // applies, so allow rather than silently disabling every rule.
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Records what a firing actually produced, so an over-productive rule is
  /// visible rather than inferred.
  Future<void> recordEffects({
    required String behaviorId,
    required String eventId,
    required int effectsCreated,
  }) async {
    try {
      await _database.db.update(
        'behavior_trigger_firings',
        {'effects_created': effectsCreated},
        where: 'behavior_id = ? AND event_id = ?',
        whereArgs: [behaviorId, eventId],
      );
    } catch (_) {
      // Non-fatal bookkeeping.
    }
  }

  /// Firings today, for diagnostics and the behaviours screen.
  Future<int> firingsToday(String behaviorId) =>
      _countForDay(behaviorId, _dayKey(DateTime.now()));

  Future<int> _countForDay(String behaviorId, String day) async {
    try {
      final rows = await _database.db.rawQuery(
        'SELECT COUNT(*) AS n FROM behavior_trigger_firings '
        'WHERE behavior_id = ? AND fired_on = ?',
        [behaviorId, day],
      );
      return (rows.first['n'] as int?) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Firing rows older than [retention] no longer bound anything.
  Future<void> prune({Duration retention = const Duration(days: 30)}) async {
    try {
      await _database.db.delete(
        'behavior_trigger_firings',
        where: 'created_at < ?',
        whereArgs: [
          DateTime.now().subtract(retention).toIso8601String(),
        ],
      );
    } catch (_) {}
  }

  static String _dayKey(DateTime moment) =>
      '${moment.year.toString().padLeft(4, '0')}-'
      '${moment.month.toString().padLeft(2, '0')}-'
      '${moment.day.toString().padLeft(2, '0')}';

  /// The message handed back when a firing is refused, phrased for the
  /// run report rather than for a log.
  static String describe(TriggerRefusal refusal, BehaviorTrigger trigger) =>
      switch (refusal) {
        TriggerRefusal.alreadyFiredForEvent =>
          '"${trigger.behaviorTitle}" has already run for this event.',
        TriggerRefusal.dailyLimitReached =>
          '"${trigger.behaviorTitle}" has already run '
              '${trigger.maxFiringsPerDay} times today, which is its limit.',
        TriggerRefusal.recursiveFiring =>
          '"${trigger.behaviorTitle}" cannot be triggered by work it '
              'created itself.',
      };
}
