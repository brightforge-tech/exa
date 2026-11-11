import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import '../database/app_database.dart';
import '../secure_storage.dart';

class MailAccount {
  /// Authenticates with a stored password / app password.
  static const authPassword = 'password';

  /// Authenticates with Google sign-in: an OAuth access token is fetched at
  /// use time and passed over IMAP/SMTP XOAUTH2. Nothing is stored.
  static const authGmail = 'gmail';

  final String id;
  final String displayName;
  final String emailAddress;
  final String username;
  final String imapHost;
  final int imapPort;
  final String? smtpHost;
  final int smtpPort;
  final bool useSsl;
  final String folder;
  final bool syncEnabled;
  final String authType;
  final DateTime? lastSyncAt;
  final String? lastError;
  final DateTime createdAt;
  final DateTime updatedAt;

  const MailAccount({
    required this.id,
    required this.displayName,
    required this.emailAddress,
    required this.username,
    required this.imapHost,
    this.imapPort = 993,
    this.smtpHost,
    this.smtpPort = 465,
    this.useSsl = true,
    this.folder = 'INBOX',
    this.syncEnabled = true,
    this.authType = authPassword,
    this.lastSyncAt,
    this.lastError,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get canSend => smtpHost != null && smtpHost!.isNotEmpty;

  bool get isGmail => authType == authGmail;

  Map<String, Object?> toRow() => {
        'id': id,
        'display_name': displayName,
        'email_address': emailAddress,
        'username': username,
        'imap_host': imapHost,
        'imap_port': imapPort,
        'smtp_host': smtpHost,
        'smtp_port': smtpPort,
        'use_ssl': useSsl ? 1 : 0,
        'folder': folder,
        'sync_enabled': syncEnabled ? 1 : 0,
        'auth_type': authType,
        'last_sync_at': lastSyncAt?.toIso8601String(),
        'last_error': lastError,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory MailAccount.fromRow(Map<String, Object?> row) => MailAccount(
        id: row['id'] as String,
        displayName: row['display_name'] as String,
        emailAddress: row['email_address'] as String,
        username: row['username'] as String,
        imapHost: row['imap_host'] as String,
        imapPort: row['imap_port'] as int? ?? 993,
        smtpHost: row['smtp_host'] as String?,
        smtpPort: row['smtp_port'] as int? ?? 465,
        useSsl: (row['use_ssl'] as int? ?? 1) == 1,
        folder: row['folder'] as String? ?? 'INBOX',
        syncEnabled: (row['sync_enabled'] as int? ?? 1) == 1,
        authType: row['auth_type'] as String? ?? authPassword,
        lastSyncAt: row['last_sync_at'] is String
            ? DateTime.tryParse(row['last_sync_at'] as String)
            : null,
        lastError: row['last_error'] as String?,
        createdAt:
            DateTime.tryParse(row['created_at'] as String? ?? '') ??
                DateTime.now(),
        updatedAt:
            DateTime.tryParse(row['updated_at'] as String? ?? '') ??
                DateTime.now(),
      );
}

/// Mail account settings live in SQLite; the password lives in platform
/// secure storage under a per-account key and never touches the database.
class MailAccountRepository {
  MailAccountRepository(this._database,
      {FlutterSecureStorage? secureStorage})
      : _secureStorage = secureStorage ?? appSecureStorage;

  final AppDatabase _database;
  final FlutterSecureStorage _secureStorage;
  static const _uuid = Uuid();

  static String _passwordKey(String accountId) =>
      'mail_password_$accountId';

  Future<MailAccount> create({
    required String displayName,
    required String emailAddress,
    required String username,
    required String password,
    required String imapHost,
    int imapPort = 993,
    String? smtpHost,
    int smtpPort = 465,
    bool useSsl = true,
  }) async {
    final now = DateTime.now();
    final account = MailAccount(
      id: _uuid.v4(),
      displayName: displayName,
      emailAddress: emailAddress,
      username: username,
      imapHost: imapHost,
      imapPort: imapPort,
      smtpHost: smtpHost,
      smtpPort: smtpPort,
      useSsl: useSsl,
      createdAt: now,
      updatedAt: now,
    );
    await _database.db.insert('mail_accounts', account.toRow());
    await _secureStorage.write(
        key: _passwordKey(account.id), value: password);
    return account;
  }

  /// Creates a Gmail account connected via Google sign-in. Server settings
  /// are fixed (Gmail's own IMAP/SMTP endpoints) and no password is stored -
  /// the mail service fetches a fresh OAuth token whenever it connects.
  /// Returns the existing account instead when this address is already
  /// connected.
  Future<MailAccount> createGmail({
    required String emailAddress,
    String? displayName,
  }) async {
    final existing = (await listAll()).where((account) =>
        account.isGmail &&
        account.emailAddress.toLowerCase() == emailAddress.toLowerCase());
    if (existing.isNotEmpty) return existing.first;

    final now = DateTime.now();
    final account = MailAccount(
      id: _uuid.v4(),
      displayName: displayName?.trim().isNotEmpty == true
          ? displayName!.trim()
          : emailAddress,
      emailAddress: emailAddress,
      username: emailAddress,
      imapHost: 'imap.gmail.com',
      smtpHost: 'smtp.gmail.com',
      authType: MailAccount.authGmail,
      createdAt: now,
      updatedAt: now,
    );
    await _database.db.insert('mail_accounts', account.toRow());
    return account;
  }

  Future<List<MailAccount>> listAll() async {
    final rows = await _database.db
        .query('mail_accounts', orderBy: 'created_at ASC');
    return rows.map(MailAccount.fromRow).toList();
  }

  Future<List<MailAccount>> listSyncEnabled() async {
    final rows = await _database.db.query('mail_accounts',
        where: 'sync_enabled = 1', orderBy: 'created_at ASC');
    return rows.map(MailAccount.fromRow).toList();
  }

  Future<MailAccount?> getById(String id) async {
    final rows = await _database.db
        .query('mail_accounts', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : MailAccount.fromRow(rows.first);
  }

  /// The stored password, or null when there is none.
  ///
  /// Throws [CredentialsUnreadable] when the platform holds a value it can
  /// no longer decrypt (reinstall or backup restore). That is deliberately
  /// distinct from "no password": the account is configured but unusable
  /// until the user re-enters it, and callers must say so rather than
  /// reporting a raw platform error every two minutes.
  Future<String?> getPassword(String accountId) async {
    try {
      return await _secureStorage.read(key: _passwordKey(accountId));
    } catch (e) {
      if (isDecryptionFailure(e)) throw const CredentialsUnreadable();
      rethrow;
    }
  }

  Future<void> setSyncEnabled(String id, bool enabled) async {
    await _database.db.update(
      'mail_accounts',
      {
        'sync_enabled': enabled ? 1 : 0,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> recordSyncResult(String id, {String? error}) async {
    await _database.db.update(
      'mail_accounts',
      {
        'last_sync_at': DateTime.now().toIso8601String(),
        'last_error': error,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<bool> delete(String id) async {
    await _secureStorage.delete(key: _passwordKey(id));
    final count = await _database.db
        .delete('mail_accounts', where: 'id = ?', whereArgs: [id]);
    return count > 0;
  }
}
