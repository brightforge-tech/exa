import '../../data/database/app_database.dart';
import '../../data/repositories/contract_repository.dart';
import '../entities/active_entity_service.dart';
import '../entities/entity_extractor.dart';
import '../entities/entity_graph_service.dart';
import '../entities/entity_relationship_repository.dart';
import '../entities/entity_repository.dart';
import '../evaluation/replay_recorder.dart';
import '../evaluation/replay_trace_repository.dart';
import '../memory/conversation_capsule.dart';
import '../memory/memory_candidate_generator.dart';
import '../memory/memory_consolidator.dart';
import '../memory/memory_context_builder.dart';
import '../memory/memory_repository.dart';
import '../memory/memory_retriever.dart';
import '../memory/memory_write_policy.dart';
import '../services/idempotency_service.dart';
import '../skills/skill_executor.dart';
import '../skills/skill_matcher.dart';
import '../skills/skill_registry.dart';
import '../skills/workflow_skill_repository.dart';
import '../tools/tool_registry.dart';

/// The intelligence layer's service bundle, wired once and handed to the
/// orchestrator. Optional by design: an orchestrator constructed without it
/// runs the original five-stage pipeline (routing, loop, report, synthesis,
/// validation) unchanged - tests and constrained builds keep working.
class AgentIntelligence {
  AgentIntelligence({
    required this.contracts,
    required this.graph,
    required this.entityExtractor,
    required this.activeEntities,
    required this.memories,
    required this.memoryRetriever,
    required this.memoryWriter,
    required this.memoryCandidateGenerator,
    required this.memoryContextBuilder,
    required this.memoryConsolidator,
    required this.skills,
    required this.skillRegistry,
    required this.skillMatcher,
    required this.skillExecutor,
    required this.replayTraces,
    required this.replayRecorder,
    required this.idempotency,
    required this.capsules,
    required this.database,
    this.conversationId = 'main',
  });

  /// Standard wiring over one database + tool registry.
  factory AgentIntelligence.standard({
    required AppDatabase database,
    required ToolRegistry registry,
  }) {
    final entityRepository = EntityRepository(database);
    final relationshipRepository = EntityRelationshipRepository(database);
    final graph = EntityGraphService(
      entityRepository: entityRepository,
      relationshipRepository: relationshipRepository,
    );
    final memories = MemoryRepository(database);
    final skills = WorkflowSkillRepository(database);
    final replayTraces = ReplayTraceRepository(database);
    return AgentIntelligence(
      contracts: ContractRepository(database),
      graph: graph,
      entityExtractor: EntityExtractor(graph),
      activeEntities: ActiveEntityService(database),
      memories: memories,
      memoryRetriever: MemoryRetriever(memories),
      memoryWriter: MemoryWriter(repository: memories),
      memoryCandidateGenerator: const MemoryCandidateGenerator(),
      memoryContextBuilder: const MemoryContextBuilder(),
      memoryConsolidator: MemoryConsolidator(memories),
      skills: skills,
      skillRegistry: SkillRegistry(skills),
      skillMatcher: SkillMatcher(skills),
      skillExecutor: SkillExecutor(registry: registry, repository: skills),
      replayTraces: replayTraces,
      replayRecorder: ReplayRecorder(repository: replayTraces),
      idempotency: const IdempotencyService(),
      capsules: ConversationCapsuleRepository(database),
      database: database,
    );
  }

  final ContractRepository contracts;
  final EntityGraphService graph;
  final EntityExtractor entityExtractor;
  final ActiveEntityService activeEntities;
  final MemoryRepository memories;
  final MemoryRetriever memoryRetriever;
  final MemoryWriter memoryWriter;
  final MemoryCandidateGenerator memoryCandidateGenerator;
  final MemoryContextBuilder memoryContextBuilder;
  final MemoryConsolidator memoryConsolidator;
  final WorkflowSkillRepository skills;
  final SkillRegistry skillRegistry;
  final SkillMatcher skillMatcher;
  final SkillExecutor skillExecutor;
  final ReplayTraceRepository replayTraces;
  final ReplayRecorder replayRecorder;
  final IdempotencyService idempotency;

  /// Semantic compaction of long topics. Derived from contracts and
  /// execution reports, never from a summarization call.
  final ConversationCapsuleRepository capsules;

  /// The shared database handle, for services (token calibration, circuit
  /// breakers) that need one without a repository of their own.
  final AppDatabase database;

  /// The chat is one thread today; all active-entity state keys off this.
  final String conversationId;

  var _seeded = false;

  /// Seeds system skills once per process. Safe to call every turn.
  Future<void> ensureSeeded() async {
    if (_seeded) return;
    await skillRegistry.seedSystemSkills();
    _seeded = true;
  }
}
