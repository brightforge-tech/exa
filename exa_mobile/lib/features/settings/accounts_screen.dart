import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/connected_account_repository.dart';
import '../../shared/providers.dart';

final accountsProvider =
    FutureProvider.autoDispose<List<ConnectedAccount>>(
        (ref) => ref.watch(connectedAccountRepositoryProvider).listAll());

/// Connected accounts (Phase 6). Browser-session accounts work today;
/// OAuth providers are scaffolded and documented in docs/INTEGRATIONS.md.
class AccountsScreen extends ConsumerWidget {
  const AccountsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountsAsync = ref.watch(accountsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Connected accounts')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddSheet(context, ref),
        child: const Icon(Icons.add_link),
      ),
      body: accountsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Error: $error')),
        data: (accounts) {
          if (accounts.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No connected accounts.\n\nAdd a browser-session account '
                  'to track which services you use through the in-app '
                  'browser, and control what Exa may read from them.\n\n'
                  'Direct Google/Microsoft API connections are planned - '
                  'see docs/INTEGRATIONS.md in the project.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 80),
            children: [
              for (final account in accounts)
                _AccountTile(account: account),
            ],
          );
        },
      ),
    );
  }

  static Future<void> _showAddSheet(
      BuildContext context, WidgetRef ref) async {
    final nameController = TextEditingController();
    String provider = 'Browser';

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
              Text('Add account',
                  style: Theme.of(sheetContext).textTheme.titleLarge),
              const SizedBox(height: 4),
              const Text(
                  'Tracks a service you sign into via the in-app browser. '
                  'Exa never sees credentials - only pages you '
                  'explicitly share.'),
              const SizedBox(height: 12),
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                    labelText: 'Label (e.g. "Work Gmail")',
                    border: OutlineInputBorder()),
                autofocus: true,
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: provider,
                decoration: const InputDecoration(
                    labelText: 'Provider', border: OutlineInputBorder()),
                items: const [
                  DropdownMenuItem(
                      value: 'Browser',
                      child: Text('Browser session (works now)')),
                  DropdownMenuItem(
                      value: 'Google',
                      child: Text('Google (API connection planned)')),
                  DropdownMenuItem(
                      value: 'Microsoft',
                      child: Text('Microsoft (API connection planned)')),
                  DropdownMenuItem(
                      value: 'Local', child: Text('Local device')),
                ],
                onChanged: (value) => provider = value ?? provider,
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () async {
                  final name = nameController.text.trim();
                  if (name.isEmpty) return;
                  await ref
                      .read(connectedAccountRepositoryProvider)
                      .create(provider: provider, displayName: name);
                  await ref.read(auditRepositoryProvider).log(
                    'user',
                    'account_connected',
                    detail: {'provider': provider, 'name': name},
                  );
                  ref.invalidate(accountsProvider);
                  if (sheetContext.mounted) {
                    Navigator.of(sheetContext).pop();
                  }
                },
                child: const Text('Add'),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

class _AccountTile extends ConsumerWidget {
  const _AccountTile({required this.account});

  final ConnectedAccount account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ExpansionTile(
      leading: Icon(switch (account.provider) {
        'Google' => Icons.mail_outline,
        'Microsoft' => Icons.business,
        'Local' => Icons.phone_android,
        _ => Icons.public,
      }),
      title: Text(account.displayName),
      subtitle: Text(
          '${account.provider} - ${account.accessType} - '
          '${account.permissionStatus}'),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      children: [
        SwitchListTile(
          dense: true,
          title: const Text('Exa may use email context'),
          value: account.emailEnabled,
          onChanged: (value) async {
            await ref
                .read(connectedAccountRepositoryProvider)
                .setCapability(account.id, email: value);
            ref.invalidate(accountsProvider);
          },
        ),
        SwitchListTile(
          dense: true,
          title: const Text('Exa may use calendar context'),
          value: account.calendarEnabled,
          onChanged: (value) async {
            await ref
                .read(connectedAccountRepositoryProvider)
                .setCapability(account.id, calendar: value);
            ref.invalidate(accountsProvider);
          },
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            icon: const Icon(Icons.link_off, size: 18),
            label: const Text('Disconnect'),
            onPressed: () async {
              await ref
                  .read(connectedAccountRepositoryProvider)
                  .delete(account.id);
              await ref.read(auditRepositoryProvider).log(
                'user',
                'account_disconnected',
                detail: {'name': account.displayName},
              );
              ref.invalidate(accountsProvider);
            },
          ),
        ),
      ],
    );
  }
}
