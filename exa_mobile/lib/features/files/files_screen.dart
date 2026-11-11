import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/models/attachment_record.dart';
import '../../shared/providers.dart';
import '../../shared/theme/exa_theme.dart';
import '../../shared/widgets/exa_empty_state.dart';

final storedFilesProvider =
    FutureProvider.autoDispose<List<AttachmentRecord>>(
        (ref) => ref.watch(attachmentRepositoryProvider).list());

class FilesScreen extends ConsumerWidget {
  const FilesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filesAsync = ref.watch(storedFilesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Files')),
      body: filesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Error: $error')),
        data: (files) {
          if (files.isEmpty) {
            return const ExaEmptyState(
              icon: Icons.folder_open,
              title: 'No stored files',
              message:
                  'Attach a file in chat and ask Exa to keep it, or ask Exa '
                  'to save something it wrote - it shows up here to read '
                  'back later.',
            );
          }
          return RefreshIndicator(
            color: ExaColors.accent,
            backgroundColor: ExaColors.surfaceHigh,
            onRefresh: () async => ref.invalidate(storedFilesProvider),
            child: ListView.separated(
              itemCount: files.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) =>
                  _FileTile(file: files[index], ref: ref),
            ),
          );
        },
      ),
    );
  }
}

class _FileTile extends StatelessWidget {
  const _FileTile({required this.file, required this.ref});

  final AttachmentRecord file;
  final WidgetRef ref;

  static IconData _iconFor(String? kind) => switch (kind) {
        'image' => Icons.image_outlined,
        'pdf' => Icons.picture_as_pdf_outlined,
        'office' => Icons.description_outlined,
        _ => Icons.text_snippet_outlined,
      };

  static String _subtitle(AttachmentRecord file) {
    final parts = <String>[];
    final size = file.sizeBytes;
    if (size != null) {
      parts.add(size < 1024 * 1024
          ? '${(size / 1024).toStringAsFixed(0)} KB'
          : '${(size / (1024 * 1024)).toStringAsFixed(1)} MB');
    }
    parts.add(DateFormat('MMM d, HH:mm').format(file.createdAt));
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final text = file.extractedText;
    final readable = text != null && text.trim().isNotEmpty;
    return ListTile(
      leading: Icon(_iconFor(file.kind)),
      title: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(_subtitle(file)),
      onTap: readable ? () => _openViewer(context, text) : null,
      trailing: PopupMenuButton<String>(
        onSelected: (value) async {
          if (value == 'share') {
            await Share.shareXFiles([XFile(file.filePath)]);
          } else if (value == 'delete') {
            await _confirmDelete(context);
          }
        },
        itemBuilder: (context) => const [
          PopupMenuItem(value: 'share', child: Text('Share')),
          PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
    );
  }

  /// Reads a stored file back in place. Notes Exa wrote (digests,
  /// summaries) are the whole point of storing them, so they need to be
  /// readable without leaving the screen.
  Future<void> _openViewer(BuildContext context, String text) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: ExaColors.surfaceHigh,
      showDragHandle: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (_, scrollController) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: ListView(
            controller: scrollController,
            children: [
              Text(file.name,
                  style: Theme.of(sheetContext).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(_subtitle(file),
                  style: Theme.of(sheetContext).textTheme.bodySmall),
              const Divider(height: 24),
              SelectableText(text),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete file?'),
        content: Text(file.name),
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
    await ref.read(attachmentRepositoryProvider).delete(file.id);
    ref.invalidate(storedFilesProvider);
  }
}
