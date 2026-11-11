import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../database/app_database.dart';
import '../models/user_collection.dart';

/// Storage for agent-defined collections and their records.
///
/// A record's field values live as one JSON object per row; reads hand back
/// flat maps (`{id, ...fields, created_at, updated_at}`) so a dynamic screen
/// renders a record exactly like a row of any built-in table. Field-level
/// filtering happens in Dart after the indexed by-collection fetch - the
/// data is one person's notes and logs, not a warehouse, and this keeps
/// every collection query off raw SQL entirely.
class UserCollectionRepository {
  UserCollectionRepository(this._database);

  final AppDatabase _database;
  static const _uuid = Uuid();

  // ------------------------------------------------------- definitions --

  /// Creates or updates a collection definition. Existing records keep any
  /// values for fields no longer declared; they simply stop rendering.
  Future<UserCollection> define({
    required String name,
    required String title,
    required List<CollectionField> fields,
  }) async {
    final existing = await getByName(name);
    final now = DateTime.now();
    final collection = UserCollection(
      name: name,
      title: title,
      fields: fields,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );
    if (existing == null) {
      await _database.db.insert('user_collections', collection.toRow());
    } else {
      await _database.db.update('user_collections', collection.toRow(),
          where: 'name = ?', whereArgs: [name]);
    }
    return collection;
  }

  Future<UserCollection?> getByName(String name) async {
    final rows = await _database.db.query('user_collections',
        where: 'name = ?', whereArgs: [name], limit: 1);
    return rows.isEmpty ? null : UserCollection.fromRow(rows.first);
  }

  Future<List<UserCollection>> listAll() async {
    final rows =
        await _database.db.query('user_collections', orderBy: 'name ASC');
    return rows.map(UserCollection.fromRow).toList();
  }

  /// Collections keyed by name - the shape [ScreenSchema.validate] takes.
  Future<Map<String, UserCollection>> asMap() async => {
        for (final collection in await listAll()) collection.name: collection,
      };

  // ----------------------------------------------------------- records --

  Future<Map<String, Object?>> addRecord({
    required String collection,
    required Map<String, Object?> values,
  }) async {
    final now = DateTime.now().toIso8601String();
    final id = _uuid.v4();
    await _database.db.insert('user_records', {
      'id': id,
      'collection': collection,
      'fields_json': jsonEncode(values),
      'created_at': now,
      'updated_at': now,
    });
    return {...values, 'id': id, 'created_at': now, 'updated_at': now};
  }

  /// Merges [values] into the record's fields. Null when no such record.
  Future<Map<String, Object?>?> updateRecord({
    required String collection,
    required String id,
    required Map<String, Object?> values,
  }) async {
    final existing = await _rawRecord(collection, id);
    if (existing == null) return null;
    final merged = {
      ..._decodeFields(existing),
      ...values,
    };
    final now = DateTime.now().toIso8601String();
    await _database.db.update(
      'user_records',
      {'fields_json': jsonEncode(merged), 'updated_at': now},
      where: 'id = ? AND collection = ?',
      whereArgs: [id, collection],
    );
    return {
      ...merged,
      'id': id,
      'created_at': existing['created_at'],
      'updated_at': now,
    };
  }

  Future<bool> deleteRecord({
    required String collection,
    required String id,
  }) async {
    final count = await _database.db.delete('user_records',
        where: 'id = ? AND collection = ?', whereArgs: [id, collection]);
    return count > 0;
  }

  Future<Map<String, Object?>?> getRecord(String collection, String id) async {
    final raw = await _rawRecord(collection, id);
    return raw == null ? null : _flatten(raw);
  }

  /// Every record of [collection], newest first, as flat row maps.
  Future<List<Map<String, Object?>>> listRecords(String collection) async {
    final rows = await _database.db.query('user_records',
        where: 'collection = ?',
        whereArgs: [collection],
        orderBy: 'created_at DESC');
    return rows.map(_flatten).toList();
  }

  Future<int> countRecords(String collection) async {
    final rows = await _database.db.rawQuery(
        'SELECT COUNT(*) AS n FROM user_records WHERE collection = ?',
        [collection]);
    return (rows.first['n'] as int?) ?? 0;
  }

  Future<Map<String, Object?>?> _rawRecord(String collection, String id) async {
    final rows = await _database.db.query('user_records',
        where: 'id = ? AND collection = ?',
        whereArgs: [id, collection],
        limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  static Map<String, Object?> _decodeFields(Map<String, Object?> raw) {
    try {
      return ((jsonDecode(raw['fields_json'] as String? ?? '{}') as Map?) ??
              const {})
          .cast<String, Object?>();
    } catch (_) {
      return const {};
    }
  }

  /// A stored row as a screen (or the agent) reads it. Field values first,
  /// then the record columns, so a field can never shadow the id.
  static Map<String, Object?> _flatten(Map<String, Object?> raw) => {
        ..._decodeFields(raw),
        'id': raw['id'],
        'created_at': raw['created_at'],
        'updated_at': raw['updated_at'],
      };
}
