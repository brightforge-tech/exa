import 'dart:async';

import 'package:sqflite/sqflite.dart';

/// Serializes writes inside one isolate and retries the one failure that is
/// actually transient.
///
/// Four things open this database: the app, the floating overlay, the
/// WorkManager isolate and the alarm isolates. Each builds its own agent
/// stack over the same file. Individual repositories being correct is not
/// enough — two of them writing at the same moment is normal here, not
/// exceptional.
///
/// WAL plus a busy timeout handles most of it at the SQLite level. This
/// adds the parts SQLite cannot: one write at a time *within* an isolate
/// (so a long transaction cannot interleave with a short one and hold the
/// file lock while it waits on the network), and a retry that fires **only**
/// for lock contention. Retrying anything else would re-run a side effect
/// that already partly happened.
class WriteCoordinator {
  WriteCoordinator({this.maxRetries = 3});

  /// Attempts for a genuinely contended write. Three covers the case this
  /// exists for — the alarm isolate and the UI landing together — without
  /// turning a deadlock into a long stall.
  final int maxRetries;

  Future<void> _tail = Future<void>.value();

  var _retryCount = 0;
  var _writeCount = 0;

  /// How many writes needed a retry. Surfaced on the reliability screen:
  /// a rising number means transactions are getting too long, not that the
  /// retry is doing its job.
  int get retryCount => _retryCount;
  int get writeCount => _writeCount;

  /// Runs [action] as the only write in flight for this isolate.
  ///
  /// Keep the body short. Anything slow — a network call, a model call,
  /// file IO — belongs outside: holding the write slot across it is exactly
  /// what makes the other isolates time out.
  Future<T> write<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await _withRetry(action));
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  /// Runs [action] inside a single transaction, serialized like [write].
  ///
  /// Use this where two rows must agree — a record and the log entry that
  /// says it exists. Committing them separately means a process death in
  /// between leaves Exa having done something it has no record of doing.
  Future<T> transaction<T>(
    Database database,
    Future<T> Function(Transaction txn) action,
  ) =>
      write(() => database.transaction(action));

  Future<T> _withRetry<T>(Future<T> Function() action) async {
    _writeCount++;
    var attempt = 0;
    while (true) {
      try {
        return await action();
      } catch (error) {
        attempt++;
        if (attempt >= maxRetries || !isTransient(error)) rethrow;
        _retryCount++;
        // Short, growing backoff: the writer we lost to is usually
        // finishing a single statement, not a long transaction.
        await Future<void>.delayed(Duration(milliseconds: 25 * attempt));
      }
    }
  }

  /// Whether an error is worth retrying.
  ///
  /// Only lock contention is. A constraint violation, a missing column or a
  /// type error will fail identically every time, and a side-effecting
  /// statement that failed halfway must never be replayed blindly.
  static bool isTransient(Object error) {
    if (error is! DatabaseException) return false;
    final message = error.toString().toLowerCase();
    return message.contains('database is locked') ||
        message.contains('sqlite_busy') ||
        message.contains('database table is locked') ||
        message.contains('busy');
  }
}

/// Startup integrity checks.
///
/// A phone kills this process routinely — Doze, a low-memory kill, the user
/// swiping the app away — and it does it mid-write as readily as anywhere
/// else. WAL makes that recoverable, but only if someone looks.
class DatabaseHealth {
  const DatabaseHealth({
    required this.isHealthy,
    required this.detail,
    this.journalMode,
  });

  final bool isHealthy;
  final String detail;
  final String? journalMode;

  Map<String, Object?> toJson() => {
        'healthy': isHealthy,
        'detail': detail,
        if (journalMode != null) 'journal_mode': journalMode,
      };

  /// Runs a fast integrity check and reports the journal mode actually in
  /// force (which is not always the one requested — some platforms decline
  /// WAL, and knowing that explains a concurrency problem that otherwise
  /// looks inexplicable).
  static Future<DatabaseHealth> check(Database database) async {
    try {
      final rows = await database.rawQuery('PRAGMA quick_check(1)');
      final result = rows.isEmpty
          ? 'unknown'
          : '${rows.first.values.firstOrNull ?? 'unknown'}';
      String? journal;
      try {
        final journalRows = await database.rawQuery('PRAGMA journal_mode');
        journal = journalRows.isEmpty
            ? null
            : '${journalRows.first.values.firstOrNull}';
      } catch (_) {
        journal = null;
      }
      return DatabaseHealth(
        isHealthy: result.toLowerCase() == 'ok',
        detail: result,
        journalMode: journal,
      );
    } catch (e) {
      return DatabaseHealth(isHealthy: false, detail: '$e');
    }
  }
}
