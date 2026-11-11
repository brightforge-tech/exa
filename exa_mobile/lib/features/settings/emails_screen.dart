import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/models/email_item.dart';
import '../../shared/providers.dart';
import '../../shared/widgets/exa_empty_state.dart';

final emailsProvider = FutureProvider.autoDispose<List<EmailItem>>(
    (ref) => ref.watch(emailRepositoryProvider).recent(limit: 100));

/// Emails the user pastes in for Exa to digest. Until Gmail/Graph API
/// integrations exist, this is the inbox the agent can actually read.
class EmailsScreen extends ConsumerWidget {
  const EmailsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final emailsAsync = ref.watch(emailsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Emails for Exa')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddSheet(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Add email'),
      ),
      body: emailsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Error: $error')),
        data: (items) {
          if (items.isEmpty) {
            return const ExaEmptyState(
              icon: Icons.mark_email_unread_outlined,
              title: 'No emails to digest',
              message:
                  'Paste an email and Exa can summarize it, pull out '
                  'tasks and meetings, and fold it into your daily '
                  'review. Or connect an account under Mail accounts.',
            );
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 88),
            children: [
              for (final email in items)
                _EmailTile(email: email),
            ],
          );
        },
      ),
    );
  }

  static Future<void> _showAddSheet(
      BuildContext context, WidgetRef ref) async {
    final subjectController = TextEditingController();
    final senderController = TextEditingController();
    final bodyController = TextEditingController();

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Add an email',
                  style: Theme.of(sheetContext).textTheme.titleLarge),
              const SizedBox(height: 4),
              const Text('Stored locally; sent to the AI service only '
                  'when you ask Exa to use it.'),
              const SizedBox(height: 12),
              TextField(
                controller: subjectController,
                decoration: const InputDecoration(
                    labelText: 'Subject', border: OutlineInputBorder()),
                autofocus: true,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: senderController,
                decoration: const InputDecoration(
                    labelText: 'From (optional)',
                    border: OutlineInputBorder()),
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: TextField(
                  controller: bodyController,
                  decoration: const InputDecoration(
                    labelText: 'Email body (paste here)',
                    border: OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                  maxLines: null,
                  minLines: 5,
                  keyboardType: TextInputType.multiline,
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () async {
                  final subject = subjectController.text.trim();
                  final body = bodyController.text.trim();
                  if (subject.isEmpty || body.isEmpty) return;
                  await ref.read(emailRepositoryProvider).add(
                        subject: subject,
                        body: body,
                        sender: senderController.text.trim().isEmpty
                            ? null
                            : senderController.text.trim(),
                        receivedAt: DateTime.now(),
                      );
                  await ref.read(auditRepositoryProvider).log(
                    'user',
                    'email_added',
                    detail: {'subject': subject},
                  );
                  ref.invalidate(emailsProvider);
                  if (sheetContext.mounted) {
                    Navigator.of(sheetContext).pop();
                  }
                },
                child: const Text('Add for Exa to digest'),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmailTile extends ConsumerWidget {
  const _EmailTile({required this.email});

  final EmailItem email;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ExpansionTile(
      leading: Icon(
        email.digested ? Icons.mark_email_read : Icons.mark_email_unread,
        color: email.digested
            ? Colors.green
            : Theme.of(context).colorScheme.primary,
      ),
      title: Text(email.subject,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text([
        if (email.sender != null) email.sender!,
        DateFormat('MMM d, HH:mm').format(email.createdAt),
        email.digested ? 'digested' : 'new',
      ].join(' - ')),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(email.body,
            maxLines: 12,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton.icon(
              icon: Icon(
                  email.digested
                      ? Icons.mark_email_unread
                      : Icons.mark_email_read,
                  size: 18),
              label: Text(
                  email.digested ? 'Mark as new' : 'Mark digested'),
              onPressed: () async {
                await ref
                    .read(emailRepositoryProvider)
                    .markDigested(email.id, digested: !email.digested);
                ref.invalidate(emailsProvider);
              },
            ),
            TextButton.icon(
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Delete'),
              onPressed: () async {
                await ref
                    .read(emailRepositoryProvider)
                    .delete(email.id);
                ref.invalidate(emailsProvider);
              },
            ),
          ],
        ),
      ],
    );
  }
}
