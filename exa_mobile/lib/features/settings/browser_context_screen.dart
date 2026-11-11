import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/models/browser_context_item.dart';
import '../../shared/providers.dart';

final browserContextProvider =
    FutureProvider.autoDispose<List<BrowserContextItem>>(
        (ref) => ref.watch(browserContextRepositoryProvider).recent(
              limit: 100,
            ));

/// Everything the user has shared from the browser - reviewable and
/// deletable, per the privacy requirements.
class BrowserContextScreen extends ConsumerWidget {
  const BrowserContextScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final itemsAsync = ref.watch(browserContextProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Shared browser pages'),
        actions: [
          IconButton(
            tooltip: 'Clear all shared pages',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (dialogContext) => AlertDialog(
                      title: const Text('Clear all shared pages?'),
                      content: const Text(
                          'Exa will no longer be able to read any '
                          'previously shared page content.'),
                      actions: [
                        TextButton(
                            onPressed: () =>
                                Navigator.pop(dialogContext, false),
                            child: const Text('Cancel')),
                        FilledButton(
                            onPressed: () =>
                                Navigator.pop(dialogContext, true),
                            child: const Text('Clear all')),
                      ],
                    ),
                  ) ??
                  false;
              if (!confirmed) return;
              await ref
                  .read(browserContextRepositoryProvider)
                  .clearAll();
              await ref.read(auditRepositoryProvider).log(
                    'user',
                    'browser_context_cleared',
                  );
              ref.invalidate(browserContextProvider);
            },
          ),
        ],
      ),
      body: itemsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Error: $error')),
        data: (items) {
          if (items.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No pages shared yet.\n\nIn the Browser tab, open a page '
                  'and tap the ✨ button to share it with Exa.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              return ExpansionTile(
                leading: const Icon(Icons.public),
                title: Text(item.pageTitle ?? 'Untitled',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  '${DateFormat('MMM d, HH:mm').format(item.createdAt)}'
                  ' - ${item.pageUrl ?? ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                childrenPadding:
                    const EdgeInsets.fromLTRB(16, 0, 16, 12),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.contentSummary ?? '',
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('Delete'),
                      onPressed: () async {
                        await ref
                            .read(browserContextRepositoryProvider)
                            .delete(item.id);
                        ref.invalidate(browserContextProvider);
                      },
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}
