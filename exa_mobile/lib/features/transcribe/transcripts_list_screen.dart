import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../data/models/transcript.dart';
import '../../shared/providers.dart';
import '../../shared/theme/exa_theme.dart';
import '../../shared/widgets/exa_empty_state.dart';

/// Lists saved voice transcripts, newest-edited first. Tap to open the editor;
/// the FAB starts a fresh transcript.
class TranscriptsListScreen extends ConsumerWidget {
  const TranscriptsListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transcriptsAsync = ref.watch(transcriptsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Transcribe')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/transcribe/new'),
        backgroundColor: ExaColors.accent,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.mic),
        label: const Text('New'),
      ),
      body: transcriptsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Error: $error')),
        data: (transcripts) {
          if (transcripts.isEmpty) {
            return ExaEmptyState(
              icon: Icons.graphic_eq,
              title: 'No transcripts yet',
              message: 'Record a voice note and it transcribes into an '
                  'editable document you can summarize and keep.',
              actionLabel: 'New transcript',
              onAction: () => context.push('/transcribe/new'),
            );
          }
          return RefreshIndicator(
            color: ExaColors.accent,
            backgroundColor: ExaColors.surfaceHigh,
            onRefresh: () async => ref.invalidate(transcriptsProvider),
            child: ListView.separated(
              padding: const EdgeInsets.only(bottom: 96),
              itemCount: transcripts.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) =>
                  _TranscriptTile(transcript: transcripts[index], ref: ref),
            ),
          );
        },
      ),
    );
  }
}

class _TranscriptTile extends StatelessWidget {
  const _TranscriptTile({required this.transcript, required this.ref});

  final Transcript transcript;
  final WidgetRef ref;

  String get _subtitle {
    final when = DateFormat('MMM d, HH:mm').format(transcript.updatedAt);
    final preview = transcript.content.trim().replaceAll('\n', ' ');
    return preview.isEmpty ? when : '$when · $preview';
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.graphic_eq),
      title: Text(transcript.title,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(_subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: transcript.summary != null
          ? const Icon(Icons.auto_awesome,
              size: 16, color: ExaColors.spark)
          : null,
      onTap: () => context.push('/transcribe/${transcript.id}'),
      onLongPress: () => _confirmDelete(context),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete transcript?'),
        content: Text(transcript.title),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(transcriptRepositoryProvider).delete(transcript.id);
    ref.invalidate(transcriptsProvider);
  }
}
