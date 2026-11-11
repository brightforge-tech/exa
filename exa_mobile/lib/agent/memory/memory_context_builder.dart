import 'dart:convert';

import 'memory_retriever.dart';
import 'models/agent_memory.dart';

/// Formats retrieved memories as the structured, clearly-caveated context
/// block the system prompt carries. Memories are supporting context, not
/// guaranteed truth - the disclaimer travels with them.
class MemoryContextBuilder {
  const MemoryContextBuilder();

  String build(MemoryRetrievalResult retrieval) {
    if (retrieval.isEmpty) return '';

    final context = <String, Object?>{
      if (retrieval.ofType(AgentMemoryType.working).isNotEmpty)
        'working_memory': [
          for (final memory in retrieval.ofType(AgentMemoryType.working))
            memory.toContextJson(),
        ],
      if (retrieval.ofType(AgentMemoryType.semantic).isNotEmpty)
        'semantic_memory': [
          for (final memory in retrieval.ofType(AgentMemoryType.semantic))
            memory.toContextJson(),
        ],
      if (retrieval.ofType(AgentMemoryType.episodic).isNotEmpty)
        'recent_episodes': [
          for (final memory in retrieval.ofType(AgentMemoryType.episodic))
            memory.toContextJson(),
        ],
      if (retrieval.ofType(AgentMemoryType.procedural).isNotEmpty)
        'procedures': [
          for (final memory in retrieval.ofType(AgentMemoryType.procedural))
            memory.toContextJson(),
        ],
      if (retrieval.ofType(AgentMemoryType.commitment).isNotEmpty)
        'commitments': [
          for (final memory in retrieval.ofType(AgentMemoryType.commitment))
            memory.toContextJson(),
        ],
    };
    if (context.isEmpty) return '';

    return 'Relevant memory (supporting context, NOT guaranteed truth - '
        'prefer current tool data and user-confirmed information over '
        'inferred memories; do not state a low-confidence memory as fact). '
        'Entries marked "tentative" have been seen once and are guesses, not '
        'established preferences - do not act on one as though the user '
        'asked for it. This block is empty when nothing was relevant enough; '
        'that is a normal outcome, not a gap to fill:\n'
        '${jsonEncode(context)}';
  }
}
