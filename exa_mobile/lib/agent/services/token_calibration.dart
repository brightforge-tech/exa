import '../../data/database/app_database.dart';
import '../models/agent_ids.dart';

/// One measured estimate-versus-actual pair.
class TokenSample {
  const TokenSample({
    required this.modelIdentifier,
    required this.estimatedInput,
    required this.actualInput,
    this.estimatedOutput = 0,
    this.actualOutput = 0,
    this.structuredRatio = 0.5,
  });

  final String modelIdentifier;
  final int estimatedInput;
  final int actualInput;
  final int estimatedOutput;
  final int actualOutput;

  /// Roughly how much of the request was JSON rather than prose, so a
  /// model's factor is not skewed by whichever kind of turn happened to be
  /// measured most.
  final double structuredRatio;
}

/// Learns each model's real tokenizer from what it reports back.
///
/// [TokenEstimator] approximates without a tokenizer, because none of the
/// three providers ships one that runs offline in Dart. That approximation
/// is deliberately conservative, and conservative in a fixed direction: it
/// over-counts, which wastes context on a 200k model and can still
/// under-count on a tokenizer that splits differently.
///
/// Every response carries the provider's own input token count. Comparing
/// it to what was predicted turns a fixed guess into a per-model measured
/// factor, without a tokenizer and without a network call.
class TokenCalibration {
  TokenCalibration(this._database);

  final AppDatabase _database;

  /// Samples kept per model. Enough to smooth noise, few enough that a
  /// changed model (the local endpoint's user loads a different GGUF)
  /// converges within a session or two.
  static const int windowSize = 30;

  /// Bounds on the correction. A factor outside this is a bug or a
  /// mis-reported count, not a tokenizer difference, and applying it would
  /// turn one bad measurement into a broken context budget.
  static const double minFactor = 0.6;
  static const double maxFactor = 1.8;

  final Map<String, double> _cache = {};

  /// Records what a call actually cost. Best-effort: calibration is an
  /// optimization, and failing to store a sample must never fail a turn.
  Future<void> record(TokenSample sample) async {
    if (sample.actualInput <= 0 || sample.estimatedInput <= 0) return;
    try {
      await _database.db.insert('token_calibration_samples', {
        'id': AgentId.turn(),
        'model_identifier': sample.modelIdentifier,
        'estimated_input': sample.estimatedInput,
        'actual_input': sample.actualInput,
        'estimated_output': sample.estimatedOutput,
        'actual_output': sample.actualOutput,
        'structured_ratio': sample.structuredRatio,
        'created_at': DateTime.now().toIso8601String(),
      });
      _cache.remove(sample.modelIdentifier);
      // Keep only the recent window; an old factor for a model the user has
      // since swapped out is worse than no factor.
      await _database.db.rawDelete(
        'DELETE FROM token_calibration_samples WHERE model_identifier = ? '
        'AND id NOT IN (SELECT id FROM token_calibration_samples '
        'WHERE model_identifier = ? ORDER BY created_at DESC LIMIT ?)',
        [sample.modelIdentifier, sample.modelIdentifier, windowSize],
      );
    } catch (_) {
      // Table missing on an un-migrated database.
    }
  }

  /// The rolling correction factor for [modelIdentifier]: multiply a raw
  /// estimate by this to get the measured one. 1.0 until there is enough
  /// evidence to justify moving.
  Future<double> factorFor(String modelIdentifier) async {
    final cached = _cache[modelIdentifier];
    if (cached != null) return cached;
    try {
      final rows = await _database.db.query(
        'token_calibration_samples',
        columns: ['estimated_input', 'actual_input'],
        where: 'model_identifier = ?',
        whereArgs: [modelIdentifier],
        orderBy: 'created_at DESC',
        limit: windowSize,
      );
      // Below this, one unusual turn would move the factor more than it
      // deserves to.
      if (rows.length < 5) {
        _cache[modelIdentifier] = 1;
        return 1;
      }
      var estimated = 0;
      var actual = 0;
      for (final row in rows) {
        estimated += (row['estimated_input'] as int?) ?? 0;
        actual += (row['actual_input'] as int?) ?? 0;
      }
      if (estimated <= 0) return 1;
      final factor =
          (actual / estimated).clamp(minFactor, maxFactor).toDouble();
      _cache[modelIdentifier] = factor;
      return factor;
    } catch (_) {
      return 1;
    }
  }

  /// Applies the learned factor to a raw estimate.
  Future<int> adjust(int rawEstimate, String modelIdentifier) async {
    final factor = await factorFor(modelIdentifier);
    return (rawEstimate * factor).ceil();
  }

  /// What is known about a model, for the reliability screen.
  Future<Map<String, Object?>> describe(String modelIdentifier) async {
    try {
      final rows = await _database.db.rawQuery(
        'SELECT COUNT(*) AS n, AVG(actual_input) AS avg_actual, '
        'AVG(estimated_input) AS avg_estimated '
        'FROM token_calibration_samples WHERE model_identifier = ?',
        [modelIdentifier],
      );
      final row = rows.isEmpty ? const <String, Object?>{} : rows.first;
      return {
        'model': modelIdentifier,
        'samples': row['n'] ?? 0,
        'factor': await factorFor(modelIdentifier),
        if (row['avg_actual'] != null) 'avg_actual_input': row['avg_actual'],
        if (row['avg_estimated'] != null)
          'avg_estimated_input': row['avg_estimated'],
      };
    } catch (_) {
      return {'model': modelIdentifier, 'samples': 0, 'factor': 1.0};
    }
  }
}

/// How many output tokens a turn should reserve.
///
/// A fixed reservation is wrong in both directions: it wastes a thousand
/// tokens of context on a two-line confirmation, and truncates a detailed
/// email analysis. The frame already sized the answer from what was asked
/// for; this turns that into the reservation.
class OutputReservation {
  const OutputReservation._();

  /// Floor for anything, so a mis-sized budget cannot produce an empty
  /// reply.
  static const int minimum = 256;

  static int forResponseBudget(int responseTokenBudget) {
    // Double the target: the JSON envelope, declared outputs and claims are
    // real output tokens too.
    final reserved = responseTokenBudget * 2;
    return reserved < minimum ? minimum : (reserved > 4096 ? 4096 : reserved);
  }

  /// The input a request may actually use:
  ///   context window - reserved output - one tool call - safety margin.
  ///
  /// The old flat 75% was a stand-in for exactly this calculation, and it
  /// is wrong at both ends of the range - too generous on a 4k model and
  /// far too stingy on a 200k one.
  static int availableInput({
    required int contextWindow,
    required int reservedOutput,
    int potentialToolCall = 512,
  }) {
    final margin = (contextWindow * 0.05).round().clamp(256, 4000);
    final available =
        contextWindow - reservedOutput - potentialToolCall - margin;
    // Never return something unusable; a tiny positive budget at least
    // fails with a readable "too big" rather than a negative-length crash.
    return available < 512 ? 512 : available;
  }
}
