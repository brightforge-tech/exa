import 'package:uuid/uuid.dart';

import '../database/app_database.dart';

class ConnectedAccount {
  static const providers = ['Google', 'Microsoft', 'Browser', 'Local'];
  static const accessTypes = [
    'oauth',
    'browser_session',
    'device_permission',
  ];

  final String id;
  final String provider;
  final String displayName;
  final String accessType;
  final bool emailEnabled;
  final bool calendarEnabled;
  final bool contactsEnabled;
  final bool filesEnabled;
  final String? syncFrequency;
  final DateTime? lastSyncAt;
  final String permissionStatus;
  final DateTime createdAt;
  final DateTime updatedAt;

  const ConnectedAccount({
    required this.id,
    required this.provider,
    required this.displayName,
    this.accessType = 'browser_session',
    this.emailEnabled = false,
    this.calendarEnabled = false,
    this.contactsEnabled = false,
    this.filesEnabled = false,
    this.syncFrequency,
    this.lastSyncAt,
    this.permissionStatus = 'Connected',
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, Object?> toRow() => {
        'id': id,
        'provider': provider,
        'display_name': displayName,
        'access_type': accessType,
        'email_enabled': emailEnabled ? 1 : 0,
        'calendar_enabled': calendarEnabled ? 1 : 0,
        'contacts_enabled': contactsEnabled ? 1 : 0,
        'files_enabled': filesEnabled ? 1 : 0,
        'sync_frequency': syncFrequency,
        'last_sync_at': lastSyncAt?.toIso8601String(),
        'permission_status': permissionStatus,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory ConnectedAccount.fromRow(Map<String, Object?> row) =>
      ConnectedAccount(
        id: row['id'] as String,
        provider: row['provider'] as String,
        displayName: row['display_name'] as String,
        accessType: row['access_type'] as String? ?? 'browser_session',
        emailEnabled: (row['email_enabled'] as int? ?? 0) == 1,
        calendarEnabled: (row['calendar_enabled'] as int? ?? 0) == 1,
        contactsEnabled: (row['contacts_enabled'] as int? ?? 0) == 1,
        filesEnabled: (row['files_enabled'] as int? ?? 0) == 1,
        syncFrequency: row['sync_frequency'] as String?,
        lastSyncAt: row['last_sync_at'] is String
            ? DateTime.tryParse(row['last_sync_at'] as String)
            : null,
        permissionStatus:
            row['permission_status'] as String? ?? 'Connected',
        createdAt:
            DateTime.tryParse(row['created_at'] as String? ?? '') ??
                DateTime.now(),
        updatedAt:
            DateTime.tryParse(row['updated_at'] as String? ?? '') ??
                DateTime.now(),
      );
}

class ConnectedAccountRepository {
  ConnectedAccountRepository(this._database);

  final AppDatabase _database;
  static const _uuid = Uuid();

  Future<ConnectedAccount> create({
    required String provider,
    required String displayName,
    String accessType = 'browser_session',
    bool emailEnabled = false,
    bool calendarEnabled = false,
  }) async {
    final now = DateTime.now();
    final account = ConnectedAccount(
      id: _uuid.v4(),
      provider: provider,
      displayName: displayName,
      accessType: accessType,
      emailEnabled: emailEnabled,
      calendarEnabled: calendarEnabled,
      createdAt: now,
      updatedAt: now,
    );
    await _database.db.insert('connected_accounts', account.toRow());
    return account;
  }

  Future<List<ConnectedAccount>> listAll() async {
    final rows = await _database.db
        .query('connected_accounts', orderBy: 'created_at ASC');
    return rows.map(ConnectedAccount.fromRow).toList();
  }

  Future<void> setCapability(
    String id, {
    bool? email,
    bool? calendar,
    bool? contacts,
    bool? files,
  }) async {
    final updates = <String, Object?>{
      'updated_at': DateTime.now().toIso8601String(),
    };
    if (email != null) updates['email_enabled'] = email ? 1 : 0;
    if (calendar != null) updates['calendar_enabled'] = calendar ? 1 : 0;
    if (contacts != null) updates['contacts_enabled'] = contacts ? 1 : 0;
    if (files != null) updates['files_enabled'] = files ? 1 : 0;
    await _database.db.update('connected_accounts', updates,
        where: 'id = ?', whereArgs: [id]);
  }

  Future<bool> delete(String id) async {
    final count = await _database.db
        .delete('connected_accounts', where: 'id = ?', whereArgs: [id]);
    return count > 0;
  }
}
