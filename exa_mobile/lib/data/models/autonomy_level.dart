/// How much Exa may do without asking.
///
/// [full] is the v3 default the user chose: no confirmation prompts
/// anywhere. The capability gate still runs on every tool call - it is where
/// the audit log, idempotency and content-trust labelling live - but under
/// [full] it allows every capability in every run mode, skips the per-domain
/// permission switches and the external-content gate, and the orchestrator
/// treats confirmation-gated tools as approved. [guarded] is v2's behaviour
/// exactly, and the v2 security tests run in it.
///
/// Two narrowings stay in both modes because they are not confirmations: a
/// turn that could not work out what the user meant is read-only until it
/// asks, and a turn typed on the lock screen keeps the lock-screen policy.
/// The write ledger's per-run caps also stay: a run that creates its two
/// hundredth record is a loop, not a decision.
enum AutonomyLevel {
  full,
  guarded;

  /// Anything but an explicit `guarded` is [full] - the default for a fresh
  /// install and for a setting written by an older build.
  static AutonomyLevel fromWire(String? name) =>
      name == 'guarded' ? guarded : full;

  String get wireName => name;

  bool get isFull => this == full;
}
