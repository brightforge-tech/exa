import 'package:uuid/uuid.dart';

/// Globally unique, prefix-typed identifiers for intelligence-layer records.
///
/// The prefix makes a bare id self-describing in logs, traces, and foreign
/// keys (`ent_`, `mem_`, `skill_`...), which matters once ids from several
/// subsystems appear in the same replay trace.
class AgentId {
  AgentId._();

  static const _uuid = Uuid();

  static String entity() => 'ent_${_uuid.v4()}';
  static String relationship() => 'rel_${_uuid.v4()}';
  static String memory() => 'mem_${_uuid.v4()}';
  static String skill() => 'skill_${_uuid.v4()}';
  static String skillRun() => 'skillrun_${_uuid.v4()}';
  static String contract() => 'contract_${_uuid.v4()}';
  static String contractAction() => 'act_${_uuid.v4()}';
  static String turn() => 'turn_${_uuid.v4()}';
  static String trace() => 'trace_${_uuid.v4()}';
  static String evaluation() => 'eval_${_uuid.v4()}';
}
