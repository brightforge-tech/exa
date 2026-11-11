import 'dart:async';

// enough_mail also exports a MailAccount class - hide it in favor of ours.
import 'package:enough_mail/enough_mail.dart' hide MailAccount;

import '../../data/repositories/email_repository.dart';
import '../../data/repositories/mail_account_repository.dart';
import '../../data/secure_storage.dart';
import 'gmail_auth_service.dart';

class MailSyncResult {
  final int fetched;
  final int added;
  final String? error;
  const MailSyncResult({this.fetched = 0, this.added = 0, this.error});
}

/// The outcome of syncing every enabled account.
///
/// Separated from a plain summary string because the caller has to make
/// three different decisions from it: whether the run *failed* (every
/// account errored), whether anything actually *changed* (worth telling the
/// user about), and how to word "new" - which is ambiguous until you know
/// the difference between messages fetched now and messages sitting
/// undigested from before.
class MailSyncSummary {
  const MailSyncSummary({
    required this.added,
    required this.accountsSynced,
    required this.errors,
    required this.summary,
  });

  /// Messages newly downloaded this run.
  final int added;

  /// Accounts that completed without error.
  final int accountsSynced;

  /// One `account: reason` entry per failed account.
  final List<String> errors;
  final String summary;

  bool get hasChanges => added > 0;

  /// Nothing worked. Distinguished from a partial failure, which still
  /// delivered mail and should not fail the whole run.
  bool get failedCompletely => accountsSynced == 0 && errors.isNotEmpty;

  bool get hasErrors => errors.isNotEmpty;
}

/// IMAP fetch + SMTP send for user-configured mail accounts.
///
/// Password accounts log in directly; Gmail accounts connected via Google
/// sign-in authenticate with a per-connection OAuth token over XOAUTH2.
/// Fetched messages land in `email_items` (deduped by Message-ID) so the
/// existing digest tools and daily review work on them unchanged.
class MailService {
  MailService({
    required this.accounts,
    required this.emails,
    GmailAuthService? gmailAuth,
  }) : gmailAuth = gmailAuth ?? GmailAuthService();

  final MailAccountRepository accounts;
  final EmailRepository emails;
  final GmailAuthService gmailAuth;

  /// The credential for [account]: an OAuth access token for Gmail
  /// sign-in accounts, the stored password otherwise. Throws [StateError]
  /// or [GmailAuthException] with a user-presentable message.
  Future<String> _credentialFor(MailAccount account) async {
    if (account.isGmail) {
      return gmailAuth.accessTokenFor(account.emailAddress);
    }
    final password = await accounts.getPassword(account.id);
    if (password == null || password.isEmpty) {
      throw StateError('No password stored for this account');
    }
    return password;
  }

  static const _fetchBatch = 15;
  // Hard ceilings so a wrong host/port/SSL setting or a stalled server can
  // never hang the agent's turn (these calls have no built-in timeout).
  static const _connectTimeout = Duration(seconds: 20);
  static const _opTimeout = Duration(seconds: 25);
  static const _fetchTimeout = Duration(seconds: 45);

  /// Fetches recent inbox messages for one account.
  Future<MailSyncResult> syncAccount(MailAccount account) async {
    final String credential;
    try {
      credential = await _credentialFor(account);
    } catch (e) {
      // A decryption failure is not a transient error: the stored secret is
      // gone for good and retrying every two minutes will never fix it, so
      // say what the user has to do instead of repeating a platform code.
      final message = switch (e) {
        GmailAuthException() => e.message,
        CredentialsUnreadable() => credentialsUnreadableMessage,
        _ => isDecryptionFailure(e) ? credentialsUnreadableMessage : '$e',
      };
      await accounts.recordSyncResult(account.id, error: message);
      return MailSyncResult(error: message);
    }

    final client = ImapClient(isLogEnabled: false);
    try {
      await client
          .connectToServer(account.imapHost, account.imapPort,
              isSecure: account.useSsl)
          .timeout(_connectTimeout);
      if (!account.useSsl) {
        await client.startTls().timeout(_opTimeout);
      }
      if (account.isGmail) {
        await client
            .authenticateWithOAuth2(account.username, credential)
            .timeout(_opTimeout);
      } else {
        await client.login(account.username, credential).timeout(_opTimeout);
      }
      final mailbox =
          await client.selectMailboxByPath(account.folder).timeout(_opTimeout);

      final total = mailbox.messagesExists;
      if (total == 0) {
        await accounts.recordSyncResult(account.id);
        return const MailSyncResult();
      }
      final start = total - _fetchBatch + 1 < 1 ? 1 : total - _fetchBatch + 1;
      final fetched = await client
          .fetchMessages(
            MessageSequence.fromRange(start, total),
            '(BODY.PEEK[])',
          )
          .timeout(_fetchTimeout);

      var added = 0;
      for (final message in fetched.messages) {
        final messageId =
            message.getHeaderValue('message-id')?.trim();
        if (messageId != null &&
            await emails.existsByExternalId(messageId)) {
          continue;
        }
        final subject = message.decodeSubject()?.trim();
        final body = _bestBody(message);
        if (body == null || body.trim().isEmpty) continue;
        await emails.add(
          subject: subject?.isNotEmpty == true ? subject! : '(no subject)',
          body: body,
          sender: message.from?.isNotEmpty == true
              ? message.from!.first.email
              : null,
          receivedAt: message.decodeDate(),
          source: 'imap',
          externalId: messageId,
        );
        added++;
      }
      await accounts.recordSyncResult(account.id);
      return MailSyncResult(fetched: fetched.messages.length, added: added);
    } on TimeoutException {
      const message = 'The mail server did not respond in time. Double-check '
          'the IMAP host, port, and SSL setting (most providers use port '
          '993 with SSL on).';
      await accounts.recordSyncResult(account.id, error: message);
      return const MailSyncResult(error: message);
    } catch (e) {
      final message = _friendly(e);
      await accounts.recordSyncResult(account.id, error: message);
      return MailSyncResult(error: message);
    } finally {
      // Best-effort cleanup, also bounded so it can't hang.
      try {
        await client.logout().timeout(const Duration(seconds: 5));
      } catch (_) {}
      try {
        await client.disconnect();
      } catch (_) {}
    }
  }

  /// Fetches all sync-enabled accounts; returns a human-readable summary.
  Future<String> syncAll() async => (await syncAllDetailed()).summary;

  /// Syncs every enabled account and reports what actually happened.
  ///
  /// The wording deliberately says "fetched" rather than "new": the app also
  /// shows a count of *undigested* mail, which counts messages downloaded on
  /// earlier runs and never processed. Calling both "new" made the two
  /// numbers look like they contradicted each other ("no new emails" beside
  /// "21 new emails") when both were correct.
  Future<MailSyncSummary> syncAllDetailed() async {
    final all = await accounts.listSyncEnabled();
    if (all.isEmpty) {
      return const MailSyncSummary(
        added: 0,
        accountsSynced: 0,
        errors: [],
        summary: 'No mail accounts configured. Add one in '
            'Settings > Mail accounts.',
      );
    }

    var added = 0;
    var synced = 0;
    final errors = <String>[];
    final parts = <String>[];
    for (final account in all) {
      final result = await syncAccount(account);
      if (result.error != null) {
        errors.add('${account.displayName}: ${result.error}');
        parts.add('${account.displayName}: failed (${result.error})');
      } else {
        synced++;
        added += result.added;
        parts.add('${account.displayName}: ${result.added} fetched');
      }
    }

    // The backlog is the number the user sees on the Today panel, so the
    // sync report has to acknowledge it or the two disagree.
    final backlog = (await emails.undigested()).length;
    final buffer = StringBuffer(parts.join('; '));
    if (backlog > 0) {
      buffer.write('. $backlog message${backlog == 1 ? '' : 's'} downloaded '
          'earlier ${backlog == 1 ? 'is' : 'are'} still waiting to be '
          'digested');
    }

    return MailSyncSummary(
      added: added,
      accountsSynced: synced,
      errors: errors,
      summary: buffer.toString(),
    );
  }

  /// Sends a plain-text email via the account's SMTP server.
  Future<void> send({
    required MailAccount account,
    required String to,
    required String subject,
    required String body,
  }) async {
    final smtpHost = account.smtpHost;
    if (smtpHost == null || smtpHost.isEmpty) {
      throw StateError(
          'Account ${account.displayName} has no SMTP server configured');
    }
    final credential = await _credentialFor(account);

    final client = SmtpClient('exa.mobile', isLogEnabled: false);
    try {
      // Port 465 = implicit TLS; 587/25 = plain connect then STARTTLS.
      final implicitTls = account.smtpPort == 465;
      await client
          .connectToServer(smtpHost, account.smtpPort, isSecure: implicitTls)
          .timeout(_connectTimeout);
      await client.ehlo().timeout(_opTimeout);
      if (!implicitTls) {
        await client.startTls().timeout(_opTimeout);
        await client.ehlo().timeout(_opTimeout);
      }
      await client
          .authenticate(
              account.username,
              credential,
              account.isGmail ? AuthMechanism.xoauth2 : AuthMechanism.plain)
          .timeout(_opTimeout);

      final builder = MessageBuilder()
        ..from = [MailAddress(account.displayName, account.emailAddress)]
        ..to = [MailAddress(null, to)]
        ..subject = subject
        ..text = body;
      await client
          .sendMessage(builder.buildMimeMessage())
          .timeout(_fetchTimeout);
    } on TimeoutException {
      throw StateError('The SMTP server did not respond in time. Check the '
          'host, port, and SSL setting (465 = SSL, 587 = STARTTLS).');
    } finally {
      try {
        await client.quit().timeout(const Duration(seconds: 5));
      } catch (_) {}
      try {
        await client.disconnect();
      } catch (_) {}
    }
  }

  static String? _bestBody(MimeMessage message) {
    final plain = message.decodeTextPlainPart();
    if (plain != null && plain.trim().isNotEmpty) return plain;
    final html = message.decodeTextHtmlPart();
    if (html == null) return null;
    // Crude tag strip - good enough for digestion.
    return html
        .replaceAll(RegExp(r'<style[^>]*>.*?</style>',
            dotAll: true, caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<script[^>]*>.*?</script>',
            dotAll: true, caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static String _friendly(Object e) {
    final text = e.toString();
    if (e is GmailAuthException) return e.message;
    if (text.contains('XOAUTH2') || text.contains('Invalid credentials')) {
      return 'Gmail rejected the sign-in token. Open Settings > Mail '
          'accounts and sign in with Google again.';
    }
    if (text.contains('authentication') || text.contains('AUTHENTICATE')) {
      return 'Login failed - check username/password (many providers '
          'need an app password)';
    }
    if (text.contains('SocketException') || text.contains('Connection')) {
      return 'Could not reach the mail server - check host/port/SSL';
    }
    return text.length > 200 ? text.substring(0, 200) : text;
  }
}
