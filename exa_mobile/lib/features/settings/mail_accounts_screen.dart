import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/repositories/mail_account_repository.dart';
import '../../services/mail/gmail_auth_service.dart';
import '../../shared/providers.dart';

final mailAccountsProvider = FutureProvider.autoDispose<List<MailAccount>>(
    (ref) => ref.watch(mailAccountRepositoryProvider).listAll());

/// Mail accounts. Gmail connects with "Sign in with Google" (OAuth, no
/// password stored); any other IMAP provider is configured manually with an
/// app password that goes straight into secure storage.
class MailAccountsScreen extends ConsumerWidget {
  const MailAccountsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountsAsync = ref.watch(mailAccountsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Mail accounts')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddSheet(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Add account'),
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
                  'No mail accounts yet.\n\nConnect an account and Exa '
                  'can fetch your mail for digestion ("sync my emails") '
                  'and send email when you ask, always with your '
                  'approval.\n\nFor Gmail, just sign in with Google - no '
                  'app password needed. Other providers (Outlook, Yahoo) '
                  'are added as IMAP accounts with an app password from '
                  'their security settings.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 88),
            children: [
              for (final account in accounts)
                _MailAccountTile(account: account),
            ],
          );
        },
      ),
    );
  }

  /// Runs the Google sign-in flow, creates (or reuses) the Gmail account,
  /// and kicks off a first sync as the connection test.
  static Future<void> _connectGmail(BuildContext context, WidgetRef ref,
      BuildContext sheetContext) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final googleAccount =
          await ref.read(gmailAuthServiceProvider).signIn();
      if (googleAccount == null) return; // User canceled the picker.
      final account =
          await ref.read(mailAccountRepositoryProvider).createGmail(
                emailAddress: googleAccount.email,
                displayName: googleAccount.displayName,
              );
      await ref.read(auditRepositoryProvider).log(
        'user',
        'mail_account_added',
        detail: {'email': account.emailAddress, 'auth': 'gmail'},
      );
      ref.invalidate(mailAccountsProvider);
      if (sheetContext.mounted) Navigator.of(sheetContext).pop();
      // First sync doubles as a connection test.
      final result =
          await ref.read(mailServiceProvider).syncAccount(account);
      ref.invalidate(mailAccountsProvider);
      messenger.showSnackBar(SnackBar(
          content: Text(result.error != null
              ? 'Signed in, but the first sync failed: ${result.error}'
              : 'Connected ${account.emailAddress} - ${result.added} '
                  'email(s) fetched')));
    } on GmailAuthException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  static Future<void> _showAddSheet(
      BuildContext context, WidgetRef ref) async {
    final name = TextEditingController();
    final email = TextEditingController();
    final username = TextEditingController();
    final password = TextEditingController();
    final imapHost = TextEditingController();
    final imapPort = TextEditingController(text: '993');
    final smtpHost = TextEditingController();
    final smtpPort = TextEditingController(text: '465');
    bool useSsl = true;
    bool saving = false;

    InputDecoration deco(String label, [String? hint]) => InputDecoration(
        labelText: label, hintText: hint, border: const OutlineInputBorder());

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
        child: StatefulBuilder(
          builder: (sheetContext, setSheetState) => SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Connect Gmail',
                    style: Theme.of(sheetContext).textTheme.titleLarge),
                const SizedBox(height: 4),
                const Text(
                    'Sign in with your Google account - no app password '
                    'needed. Exa asks Google for mail access and never '
                    'stores a password or token.'),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.account_circle_outlined),
                  label: const Text('Sign in with Google'),
                  onPressed: () => _connectGmail(context, ref, sheetContext),
                ),
                const SizedBox(height: 16),
                Row(children: [
                  const Expanded(child: Divider()),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text('or add any IMAP account',
                        style:
                            Theme.of(sheetContext).textTheme.bodySmall),
                  ),
                  const Expanded(child: Divider()),
                ]),
                const SizedBox(height: 16),
                const Text(
                    'Password is stored in your device\'s secure storage. '
                    'Most providers need an app password.'),
                const SizedBox(height: 12),
                TextField(
                    controller: name,
                    decoration: deco('Label', 'e.g. Work mail')),
                const SizedBox(height: 8),
                TextField(
                    controller: email,
                    keyboardType: TextInputType.emailAddress,
                    decoration: deco('Email address'),
                    onChanged: (value) {
                      if (username.text.isEmpty ||
                          username.text == value.substring(
                              0, value.length - 1)) {
                        username.text = value;
                      }
                    }),
                const SizedBox(height: 8),
                TextField(
                    controller: username,
                    decoration:
                        deco('Username', 'usually the email address')),
                const SizedBox(height: 8),
                TextField(
                    controller: password,
                    obscureText: true,
                    decoration: deco('Password / app password')),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                      flex: 3,
                      child: TextField(
                          controller: imapHost,
                          decoration:
                              deco('IMAP host', 'imap.example.com'))),
                  const SizedBox(width: 8),
                  Expanded(
                      child: TextField(
                          controller: imapPort,
                          keyboardType: TextInputType.number,
                          decoration: deco('Port'))),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                      flex: 3,
                      child: TextField(
                          controller: smtpHost,
                          decoration: deco('SMTP host (optional)',
                              'smtp.example.com - needed to send'))),
                  const SizedBox(width: 8),
                  Expanded(
                      child: TextField(
                          controller: smtpPort,
                          keyboardType: TextInputType.number,
                          decoration: deco('Port'))),
                ]),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Use SSL/TLS'),
                  subtitle:
                      const Text('Off = STARTTLS (ports 143/587)'),
                  value: useSsl,
                  onChanged: (value) =>
                      setSheetState(() => useSsl = value),
                ),
                const SizedBox(height: 4),
                FilledButton(
                  onPressed: saving
                      ? null
                      : () async {
                          if (email.text.trim().isEmpty ||
                              password.text.isEmpty ||
                              imapHost.text.trim().isEmpty) {
                            return;
                          }
                          setSheetState(() => saving = true);
                          final repo =
                              ref.read(mailAccountRepositoryProvider);
                          final account = await repo.create(
                            displayName: name.text.trim().isEmpty
                                ? email.text.trim()
                                : name.text.trim(),
                            emailAddress: email.text.trim(),
                            username: username.text.trim().isEmpty
                                ? email.text.trim()
                                : username.text.trim(),
                            password: password.text,
                            imapHost: imapHost.text.trim(),
                            imapPort:
                                int.tryParse(imapPort.text) ?? 993,
                            smtpHost: smtpHost.text.trim().isEmpty
                                ? null
                                : smtpHost.text.trim(),
                            smtpPort:
                                int.tryParse(smtpPort.text) ?? 465,
                            useSsl: useSsl,
                          );
                          await ref.read(auditRepositoryProvider).log(
                            'user',
                            'mail_account_added',
                            detail: {'email': account.emailAddress},
                          );
                          ref.invalidate(mailAccountsProvider);
                          if (sheetContext.mounted) {
                            Navigator.of(sheetContext).pop();
                          }
                          // First sync doubles as a connection test.
                          final result = await ref
                              .read(mailServiceProvider)
                              .syncAccount(account);
                          ref.invalidate(mailAccountsProvider);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                  content: Text(result.error != null
                                      ? 'Connection failed: '
                                          '${result.error}'
                                      : 'Connected - ${result.added} '
                                          'email(s) fetched')),
                            );
                          }
                        },
                  child: Text(saving ? 'Saving...' : 'Save & test'),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MailAccountTile extends ConsumerWidget {
  const _MailAccountTile({required this.account});

  final MailAccount account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasError = account.lastError != null;
    return ExpansionTile(
      leading: Icon(
        hasError
            ? Icons.error_outline
            : account.isGmail
                ? Icons.g_mobiledata
                : Icons.mail_outline,
        color: hasError ? Colors.red : Colors.green,
      ),
      title: Text(account.displayName),
      subtitle: Text([
        account.emailAddress,
        if (account.isGmail) 'Google sign-in',
        if (account.lastSyncAt != null)
          'synced ${DateFormat('MMM d, HH:mm').format(account.lastSyncAt!)}',
        if (hasError) 'error',
      ].join(' - ')),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(account.isGmail
            ? 'Gmail via Google sign-in - sync and send enabled, no '
                'password stored'
            : 'IMAP ${account.imapHost}:${account.imapPort}'
                '${account.canSend ? ' - SMTP ${account.smtpHost}:${account.smtpPort}' : ' - sending not configured'}'),
        if (hasError)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(account.lastError!,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.error)),
          ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Include in email sync'),
          value: account.syncEnabled,
          onChanged: (value) async {
            await ref
                .read(mailAccountRepositoryProvider)
                .setSyncEnabled(account.id, value);
            ref.invalidate(mailAccountsProvider);
          },
        ),
        Row(
          children: [
            TextButton.icon(
              icon: const Icon(Icons.sync, size: 18),
              label: const Text('Sync now'),
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                final result = await ref
                    .read(mailServiceProvider)
                    .syncAccount(account);
                ref.invalidate(mailAccountsProvider);
                messenger.showSnackBar(SnackBar(
                    content: Text(result.error != null
                        ? 'Sync failed: ${result.error}'
                        : '${result.added} new email(s)')));
              },
            ),
            TextButton.icon(
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Remove'),
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                        title: const Text('Remove account?'),
                        content: Text(
                            '${account.emailAddress}\n\n'
                            '${account.isGmail ? 'The Google connection is '
                                'signed out.' : 'The stored password is '
                                'deleted.'} Already-fetched emails '
                            'stay in Emails for Exa.'),
                        actions: [
                          TextButton(
                              onPressed: () =>
                                  Navigator.pop(dialogContext, false),
                              child: const Text('Cancel')),
                          FilledButton(
                              onPressed: () =>
                                  Navigator.pop(dialogContext, true),
                              child: const Text('Remove')),
                        ],
                      ),
                    ) ??
                    false;
                if (!confirmed) return;
                final repo = ref.read(mailAccountRepositoryProvider);
                await repo.delete(account.id);
                if (account.isGmail) {
                  // Disconnect the Google session once no Gmail accounts
                  // remain (there is one Play Services session app-wide).
                  final remaining = await repo.listAll();
                  if (!remaining.any((a) => a.isGmail)) {
                    await ref.read(gmailAuthServiceProvider).signOut();
                  }
                }
                await ref.read(auditRepositoryProvider).log(
                  'user',
                  'mail_account_removed',
                  detail: {'email': account.emailAddress},
                );
                ref.invalidate(mailAccountsProvider);
              },
            ),
          ],
        ),
      ],
    );
  }
}
