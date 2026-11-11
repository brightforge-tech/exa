import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import '../agent/tools/tool_failure.dart';
import '../data/database/app_database.dart';

/// Whether a service is currently worth talking to.
enum CircuitState {
  /// Normal. Calls go through.
  closed,

  /// Failing. Calls are refused without being attempted.
  open,

  /// Probing. One call is allowed through to see if it recovered.
  halfOpen;

  String get wireName => name;

  static CircuitState fromWireName(String? name) =>
      CircuitState.values.firstWhere(
        (state) => state.name == name?.trim(),
        orElse: () => CircuitState.closed,
      );
}

/// The current health of one (service, account) pair.
class CircuitStatus {
  const CircuitStatus({
    required this.service,
    required this.accountId,
    required this.state,
    required this.consecutiveFailures,
    this.failureKind,
    this.lastSuccessAt,
    this.lastFailureAt,
    this.retryAfter,
    this.notifiedAt,
  });

  final String service;
  final String accountId;
  final CircuitState state;
  final int consecutiveFailures;
  final String? failureKind;
  final DateTime? lastSuccessAt;
  final DateTime? lastFailureAt;
  final DateTime? retryAfter;

  /// When the user was last told. Set so they are told once, not on every
  /// tick of a two-minute sync.
  final DateTime? notifiedAt;

  bool get isHealthy => state == CircuitState.closed;

  /// Whether a call may be attempted right now.
  bool allowsAttempt(DateTime now) => switch (state) {
        CircuitState.closed => true,
        CircuitState.halfOpen => true,
        CircuitState.open =>
          retryAfter != null && !now.isBefore(retryAfter!),
      };

  Map<String, Object?> toJson() => {
        'service': service,
        if (accountId.isNotEmpty) 'account_id': accountId,
        'state': state.wireName,
        'consecutive_failures': consecutiveFailures,
        if (failureKind != null) 'failure_kind': failureKind,
        if (retryAfter != null) 'retry_after': retryAfter!.toIso8601String(),
        if (lastSuccessAt != null)
          'last_success_at': lastSuccessAt!.toIso8601String(),
      };
}

/// Stops Exa hammering a service that is not answering.
///
/// The occurrence ledger already makes duplicate execution impossible and
/// dead-letters a job that keeps failing. This is the other half: a mail
/// account whose password changed fails identically every two minutes, and
/// the ledger dutifully retries and dead-letters *each occurrence*
/// separately. From the provider's side that is a login attempt every two
/// minutes; from the user's side it is a notification storm about one
/// problem.
///
/// A breaker turns that into: notice, stop, tell the user once, probe
/// occasionally, resume by itself when the service comes back.
class ServiceCircuitBreaker {
  ServiceCircuitBreaker(this._database);

  final AppDatabase _database;

  /// Consecutive failures before the circuit opens. Three tolerates a
  /// genuine blip on a phone changing networks without pretending a
  /// changed password might fix itself.
  static const int failureThreshold = 3;

  /// How long to stay open before probing, doubling each time up to the
  /// cap. An authentication failure will not fix itself, so probing it
  /// often is pure waste.
  static const Duration baseCooldown = Duration(minutes: 5);
  static const Duration maxCooldown = Duration(hours: 6);

  Future<CircuitStatus> statusOf(String service, {String accountId = ''}) async {
    try {
      final rows = await _database.db.query(
        'service_circuits',
        where: 'service = ? AND account_id = ?',
        whereArgs: [service, accountId],
        limit: 1,
      );
      if (rows.isEmpty) {
        return CircuitStatus(
          service: service,
          accountId: accountId,
          state: CircuitState.closed,
          consecutiveFailures: 0,
        );
      }
      final row = rows.first;
      return CircuitStatus(
        service: service,
        accountId: accountId,
        state: CircuitState.fromWireName(row['circuit_state'] as String?),
        consecutiveFailures: (row['consecutive_failures'] as int?) ?? 0,
        failureKind: row['failure_kind'] as String?,
        lastSuccessAt:
            DateTime.tryParse(row['last_success_at'] as String? ?? ''),
        lastFailureAt:
            DateTime.tryParse(row['last_failure_at'] as String? ?? ''),
        retryAfter: DateTime.tryParse(row['retry_after'] as String? ?? ''),
        notifiedAt: DateTime.tryParse(row['notified_at'] as String? ?? ''),
      );
    } catch (_) {
      // A database without the table yet must not stop the service working.
      return CircuitStatus(
        service: service,
        accountId: accountId,
        state: CircuitState.closed,
        consecutiveFailures: 0,
      );
    }
  }

  /// Whether to attempt a call now. When false, the caller reports the
  /// stored reason instead of trying.
  Future<bool> allows(String service, {String accountId = ''}) async {
    final status = await statusOf(service, accountId: accountId);
    if (status.state == CircuitState.closed) return true;
    final now = DateTime.now();
    if (!status.allowsAttempt(now)) return false;
    // Cooldown elapsed: let exactly one call through to find out.
    if (status.state == CircuitState.open) {
      await _write(service, accountId, {
        'circuit_state': CircuitState.halfOpen.wireName,
        'updated_at': now.toIso8601String(),
      });
    }
    return true;
  }

  /// The service answered. Everything resets — including the "told the
  /// user" flag, so a second outage is reported rather than swallowed.
  Future<void> recordSuccess(String service, {String accountId = ''}) async {
    final now = DateTime.now().toIso8601String();
    await _write(service, accountId, {
      'consecutive_failures': 0,
      'circuit_state': CircuitState.closed.wireName,
      'failure_kind': null,
      'last_success_at': now,
      'retry_after': null,
      'notified_at': null,
      'updated_at': now,
    });
  }

  /// The service failed. Returns the resulting status, including whether
  /// the circuit has just opened (the moment worth notifying about).
  Future<CircuitStatus> recordFailure(
    String service, {
    String accountId = '',
    ToolFailureKind kind = ToolFailureKind.transientNetwork,
  }) async {
    final previous = await statusOf(service, accountId: accountId);
    final failures = previous.consecutiveFailures + 1;
    final now = DateTime.now();

    // Authentication does not recover on its own. Open immediately rather
    // than spending three attempts proving it.
    final shouldOpen = failures >= failureThreshold ||
        kind == ToolFailureKind.authenticationRequired;

    final cooldown = _cooldownFor(failures);
    final state = shouldOpen ? CircuitState.open : CircuitState.closed;

    await _write(service, accountId, {
      'consecutive_failures': failures,
      'circuit_state': state.wireName,
      'failure_kind': kind.wireName,
      'last_failure_at': now.toIso8601String(),
      'retry_after':
          shouldOpen ? now.add(cooldown).toIso8601String() : null,
      'updated_at': now.toIso8601String(),
    });

    return CircuitStatus(
      service: service,
      accountId: accountId,
      state: state,
      consecutiveFailures: failures,
      failureKind: kind.wireName,
      lastSuccessAt: previous.lastSuccessAt,
      lastFailureAt: now,
      retryAfter: shouldOpen ? now.add(cooldown) : null,
      notifiedAt: previous.notifiedAt,
    );
  }

  /// True the first time an open circuit should be reported. Marks it, so
  /// the user hears about an outage once rather than every sync tick.
  Future<bool> shouldNotify(String service, {String accountId = ''}) async {
    final status = await statusOf(service, accountId: accountId);
    if (status.state != CircuitState.open) return false;
    if (status.notifiedAt != null) return false;
    await _write(service, accountId, {
      'notified_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    return true;
  }

  /// Everything currently unhealthy, for the reliability screen.
  Future<List<CircuitStatus>> unhealthy() async {
    try {
      final rows = await _database.db.query(
        'service_circuits',
        where: "circuit_state != 'closed'",
        orderBy: 'updated_at DESC',
      );
      return [
        for (final row in rows)
          CircuitStatus(
            service: row['service'] as String,
            accountId: row['account_id'] as String? ?? '',
            state: CircuitState.fromWireName(row['circuit_state'] as String?),
            consecutiveFailures: (row['consecutive_failures'] as int?) ?? 0,
            failureKind: row['failure_kind'] as String?,
            lastSuccessAt:
                DateTime.tryParse(row['last_success_at'] as String? ?? ''),
            lastFailureAt:
                DateTime.tryParse(row['last_failure_at'] as String? ?? ''),
            retryAfter:
                DateTime.tryParse(row['retry_after'] as String? ?? ''),
          ),
      ];
    } catch (_) {
      return const [];
    }
  }

  static Duration _cooldownFor(int failures) {
    final steps = (failures - failureThreshold).clamp(0, 8);
    final minutes = baseCooldown.inMinutes * (1 << steps);
    return minutes >= maxCooldown.inMinutes ? maxCooldown : Duration(minutes: minutes);
  }

  Future<void> _write(
      String service, String accountId, Map<String, Object?> values) async {
    try {
      final existing = await _database.db.query(
        'service_circuits',
        where: 'service = ? AND account_id = ?',
        whereArgs: [service, accountId],
        limit: 1,
      );
      if (existing.isEmpty) {
        await _database.db.insert(
          'service_circuits',
          {
            'service': service,
            'account_id': accountId,
            'consecutive_failures': 0,
            'circuit_state': CircuitState.closed.wireName,
            'updated_at': DateTime.now().toIso8601String(),
            ...values,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        return;
      }
      await _database.db.update(
        'service_circuits',
        values,
        where: 'service = ? AND account_id = ?',
        whereArgs: [service, accountId],
      );
    } catch (_) {
      // Un-migrated database: health tracking is unavailable, the service
      // itself still works.
    }
  }
}

/// Service names, so callers and the reliability screen agree.
class ServiceNames {
  ServiceNames._();

  static const mail = 'mail';
  static const calendar = 'calendar';
  static const browser = 'browser';
  static const aiProvider = 'ai_provider';

  /// The file-audio transcription endpoint. Its own name, rather than riding
  /// on [aiProvider]: a local server that answers chat but cannot do
  /// `audio/transcriptions` is a real and common state, and a breaker shared
  /// with chat would pause the assistant because of a missing whisper model.
  static const transcription = 'transcription';
}
