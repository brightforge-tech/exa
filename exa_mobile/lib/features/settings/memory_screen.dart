import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../agent/memory/models/agent_memory.dart';
import '../../shared/providers.dart';

final _memoriesProvider =
    FutureProvider.autoDispose<List<AgentMemory>>((ref) async {
  return ref.watch(memoryRepositoryProvider).listAll();
});

/// Settings > Memory: review what Exa has remembered, delete individual
/// memories, clear a whole type, and switch long-term memory off entirely.
/// Memory must stay inspectable - nothing here is hidden state.
class MemoryScreen extends ConsumerWidget {
  const MemoryScreen({super.key});

  static const _typeLabels = {
    AgentMemoryType.working: 'Working (short-lived)',
    AgentMemoryType.episodic: 'Episodes (what happened)',
    AgentMemoryType.semantic: 'Facts and preferences',
    AgentMemoryType.procedural: 'Routines',
    AgentMemoryType.commitment: 'Commitments',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final memoriesAsync = ref.watch(_memoriesProvider);
    final settings = ref.watch(settingsRepositoryProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Memory'),
        actions: [
          PopupMenuButton<AgentMemoryType>(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: 'Clear memories by type',
            onSelected: (type) async {
              final confirmed = await _confirm(
                  context,
                  'Clear ${_typeLabels[type]}?',
                  'Every memory of this type is permanently deleted.');
              if (confirmed) {
                await ref.read(memoryRepositoryProvider).deleteByType(type);
                ref.invalidate(_memoriesProvider);
              }
            },
            itemBuilder: (context) => [
              for (final type in AgentMemoryType.values)
                PopupMenuItem(
                  value: type,
                  child: Text('Clear ${_typeLabels[type]!.toLowerCase()}'),
                ),
            ],
          ),
        ],
      ),
      body: memoriesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Could not load: $error')),
        data: (memories) {
          final byType = <AgentMemoryType, List<AgentMemory>>{};
          for (final memory in memories) {
            byType.putIfAbsent(memory.type, () => []).add(memory);
          }
          return ListView(
            children: [
              FutureBuilder<bool>(
                future: settings.isLongTermMemoryEnabled(),
                builder: (context, snapshot) => SwitchListTile(
                  title: const Text('Long-term memory'),
                  subtitle: const Text(
                      'When off, Exa stops saving new memories. Existing '
                      'ones stay until you delete them.'),
                  value: snapshot.data ?? true,
                  onChanged: (enabled) async {
                    await settings.setLongTermMemoryEnabled(enabled);
                    ref.invalidate(_memoriesProvider);
                  },
                ),
              ),
              if (memories.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(
                      child: Text('Nothing remembered yet. Memories appear '
                          'here as you work with Exa.')),
                ),
              for (final type in AgentMemoryType.values)
                if (byType[type]?.isNotEmpty ?? false) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(_typeLabels[type]!,
                        style: Theme.of(context).textTheme.titleSmall),
                  ),
                  for (final memory in byType[type]!)
                    _MemoryTile(
                      memory: memory,
                      onDelete: () async {
                        await ref
                            .read(memoryRepositoryProvider)
                            .delete(memory.id);
                        ref.invalidate(_memoriesProvider);
                      },
                    ),
                ],
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }

  static Future<bool> _confirm(
      BuildContext context, String title, String body) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: Text(body),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Clear'),
              ),
            ],
          ),
        ) ??
        false;
  }
}

class _MemoryTile extends StatelessWidget {
  const _MemoryTile({required this.memory, required this.onDelete});

  final AgentMemory memory;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final detail = <String>[
      'confidence ${(memory.confidence * 100).round()}%',
      if (memory.userConfirmed) 'confirmed by you',
      if (memory.isArchived) 'archived',
      if (memory.expiresAt != null)
        'expires ${DateFormat.yMMMd().format(memory.expiresAt!)}',
      DateFormat.yMMMd().format(memory.updatedAt),
    ].join(' - ');

    return ListTile(
      dense: true,
      title: Text(memory.content,
          maxLines: 3, overflow: TextOverflow.ellipsis),
      subtitle: Text(detail),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: 'Forget this',
        onPressed: onDelete,
      ),
    );
  }
}
