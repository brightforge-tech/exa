/// Why a tool call did not succeed.
///
/// "It failed" is not enough to decide what to do next, so the model was
/// left to work it out from an error string — and a model reading "no
/// results" reliably decides to search again, differently, forever. Typing
/// the failure lets the recovery be programmed instead of improvised.
enum ToolFailureKind {
  /// The arguments were wrong. One corrected call is reasonable.
  invalidArguments,

  /// A gate refused it. Never work around a gate.
  permissionDenied,

  /// The user must reconnect an account. Nothing retryable here.
  authenticationRequired,

  /// A network blip. Safe to retry a read.
  transientNetwork,

  /// Backed off by the service. Retry only when there is budget.
  rateLimited,

  /// Something changed underneath. Re-read before retrying.
  conflict,

  /// The target does not exist.
  notFound,

  /// The call worked; there was nothing to find.
  noResults,

  /// Some of it worked. Record exactly which part.
  partialSuccess,

  /// It will fail the same way every time.
  permanentFailure,

  /// Stopped deliberately (timeout, user cancel).
  cancelled;

  String get wireName => name;

  /// Whether retrying the identical call could plausibly succeed.
  bool get isRetryable =>
      this == transientNetwork || this == rateLimited || this == conflict;

  /// Whether a *side-effecting* call may be retried. Only with the same
  /// idempotency key: a create that timed out may well have succeeded.
  bool get isSafeToRetryWithKey => isRetryable;
}

/// What the agent should do about a typed failure.
enum RecoveryAction {
  /// Try once more with corrected arguments.
  correctAndRetryOnce,

  /// Retry the identical call after a delay.
  retryAfterBackoff,

  /// Revise the query once — not repeatedly.
  reviseSearchOnce,

  /// Stop and tell the user what they need to do.
  stopAndTellUser,

  /// Record what happened and carry on with the rest of the task.
  recordAndContinue,

  /// Stop this line of work entirely.
  abandon,
}

/// The programmed response to each failure kind.
class ToolRecoveryPolicy {
  const ToolRecoveryPolicy();

  /// How many times one turn may retry the same tool for the same reason.
  static const int maxRetriesPerTool = 1;

  /// Identical calls in a row before the loop is considered stuck. Two is
  /// enough: the first repeat can be a genuine retry, the third never is.
  static const int repeatedCallLimit = 3;

  RecoveryAction actionFor(ToolFailureKind kind) => switch (kind) {
        ToolFailureKind.invalidArguments => RecoveryAction.correctAndRetryOnce,
        // Never ask the model to route around a gate. The refusal is the
        // answer; the user hears about it.
        ToolFailureKind.permissionDenied => RecoveryAction.recordAndContinue,
        ToolFailureKind.authenticationRequired => RecoveryAction.stopAndTellUser,
        ToolFailureKind.transientNetwork => RecoveryAction.retryAfterBackoff,
        ToolFailureKind.rateLimited => RecoveryAction.retryAfterBackoff,
        ToolFailureKind.conflict => RecoveryAction.correctAndRetryOnce,
        ToolFailureKind.notFound => RecoveryAction.recordAndContinue,
        ToolFailureKind.noResults => RecoveryAction.reviseSearchOnce,
        ToolFailureKind.partialSuccess => RecoveryAction.recordAndContinue,
        ToolFailureKind.permanentFailure => RecoveryAction.abandon,
        ToolFailureKind.cancelled => RecoveryAction.abandon,
      };

  /// The guidance handed back to the model in place of a bare error, so its
  /// next step matches what the policy already decided.
  String guidanceFor(ToolFailureKind kind, String toolName) =>
      switch (actionFor(kind)) {
        RecoveryAction.correctAndRetryOnce =>
          'Fix the arguments and call $toolName once more. If it fails '
              'again, report it rather than trying a third time.',
        RecoveryAction.retryAfterBackoff =>
          'This was a temporary problem. One more attempt is reasonable; '
              'after that, tell the user it is unavailable right now.',
        RecoveryAction.reviseSearchOnce =>
          'Nothing matched. Broaden or rephrase the search once. If it is '
              'still empty, say so plainly - an empty result is an answer.',
        RecoveryAction.stopAndTellUser =>
          'This needs the user to reconnect the account in Settings. Do not '
              'retry; tell them what to do.',
        RecoveryAction.recordAndContinue =>
          'Carry on with the rest of the task and say plainly in your '
              'summary what you could not do.',
        RecoveryAction.abandon =>
          'This will not succeed. Stop trying it and report it.',
      };

  /// Classifies a failure from the tool's own signals.
  ///
  /// Message matching is a fallback, not the mechanism: [wasDenied] and the
  /// exception type carry the truth where they are available. A message
  /// that matches nothing becomes [ToolFailureKind.permanentFailure], which
  /// stops the loop rather than encouraging another attempt — the safe
  /// direction when the failure is not understood.
  static ToolFailureKind classify({
    required String? error,
    bool wasDenied = false,
    Object? exception,
  }) {
    if (wasDenied) return ToolFailureKind.permissionDenied;
    if (exception is Exception &&
        exception.runtimeType.toString().contains('Timeout')) {
      return ToolFailureKind.transientNetwork;
    }
    final message = (error ?? '').toLowerCase();
    if (message.isEmpty) return ToolFailureKind.permanentFailure;

    if (message.contains('missing required parameter') ||
        message.contains('should be of type') ||
        message.contains('invalid') && message.contains('argument')) {
      return ToolFailureKind.invalidArguments;
    }
    if (message.contains('permission') || message.contains('not allowed') ||
        message.contains('blocked') || message.contains('declined')) {
      return ToolFailureKind.permissionDenied;
    }
    if (message.contains('sign in') ||
        message.contains('authenticat') ||
        message.contains('credential') ||
        message.contains('reconnect') ||
        message.contains('app password') ||
        message.contains('401')) {
      return ToolFailureKind.authenticationRequired;
    }
    if (message.contains('rate limit') ||
        message.contains('too many requests') ||
        message.contains('429')) {
      return ToolFailureKind.rateLimited;
    }
    if (message.contains('timed out') ||
        message.contains('timeout') ||
        message.contains('unreachable') ||
        message.contains('connection') ||
        message.contains('socket') ||
        message.contains('network')) {
      return ToolFailureKind.transientNetwork;
    }
    if (message.contains('not found') ||
        message.contains('no such') ||
        message.contains('does not exist')) {
      return ToolFailureKind.notFound;
    }
    if (message.contains('no results') ||
        message.contains('nothing matched') ||
        message.contains('no matches')) {
      return ToolFailureKind.noResults;
    }
    if (message.contains('conflict') || message.contains('already exists')) {
      return ToolFailureKind.conflict;
    }
    if (message.contains('cancel')) return ToolFailureKind.cancelled;
    return ToolFailureKind.permanentFailure;
  }
}

/// Tracks repeated and failed calls within one turn, so the loop can be
/// stopped by code rather than by the iteration backstop.
class ToolAttemptLedger {
  final Map<String, int> _failuresByTool = {};
  final Map<String, int> _identicalCalls = {};

  /// A stable signature for "the same call again": tool plus arguments.
  static String signature(String tool, Map<String, Object?> arguments) {
    final keys = arguments.keys.toList()..sort();
    return '$tool(${keys.map((k) => '$k=${arguments[k]}').join(',')})';
  }

  /// Records an attempt and returns the refusal to hand back, or null when
  /// the call should proceed.
  String? beforeCall(String tool, Map<String, Object?> arguments) {
    final key = signature(tool, arguments);
    final count = (_identicalCalls[key] ?? 0) + 1;
    _identicalCalls[key] = count;
    if (count > ToolRecoveryPolicy.repeatedCallLimit) {
      return 'You have now called $tool with these exact arguments $count '
          'times. It will not behave differently. Use what you have and '
          'tell the user what did not work.';
    }
    return null;
  }

  void recordFailure(String tool, ToolFailureKind kind) {
    _failuresByTool['$tool:${kind.wireName}'] =
        (_failuresByTool['$tool:${kind.wireName}'] ?? 0) + 1;
  }

  /// Whether this tool has already failed this way often enough that
  /// another attempt is just noise.
  bool exhausted(String tool, ToolFailureKind kind) =>
      (_failuresByTool['$tool:${kind.wireName}'] ?? 0) >
      ToolRecoveryPolicy.maxRetriesPerTool;

  Map<String, Object?> toJson() => {
        if (_failuresByTool.isNotEmpty) 'failures': _failuresByTool,
        'distinct_calls': _identicalCalls.length,
      };
}
