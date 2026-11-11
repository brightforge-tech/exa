import 'package:sqflite/sqflite.dart' show Database;

import '../../data/models/user_collection.dart';
import '../../data/repositories/user_collection_repository.dart';
import 'screen_schema.dart';

/// Executes a validated screen data source - the one place that knows how.
///
/// Built-in tables go through SQL (identifiers were allowlist-checked by
/// [ScreenSchema.validate], values are always bound args). Collection
/// records are fetched by collection and filtered in Dart with the same
/// semantics. Both the renderer and `create_dynamic_screen`'s row-count
/// check call this, so a screen can never count differently than it renders.
class ScreenQuery {
  const ScreenQuery._();

  static Future<List<Map<String, Object?>>> rowsFor({
    required Database db,
    required UserCollectionRepository records,
    required Map<String, Object?> source,
    required Map<String, UserCollection> collections,
  }) async {
    final table = source['table'] as String;
    if (collections.containsKey(table)) {
      final all = await records.listRecords(table);
      final matched =
          [for (final row in all) if (ScreenSchema.rowMatches(row, source)) row];
      return ScreenSchema.orderAndLimit(matched, source);
    }
    final (where, args) = ScreenSchema.buildWhere(source);
    final orderBy = source['order_by'] as String?;
    final order =
        (source['order'] as String?)?.toLowerCase() == 'desc' ? 'DESC' : 'ASC';
    return db.query(
      table,
      where: where,
      whereArgs: args.isEmpty ? null : args,
      orderBy: orderBy == null ? null : '$orderBy $order',
      // Coerced, not cast: a model that writes `"limit": 50.0` (or "50")
      // used to bring the whole screen down with a type error.
      limit: (source['limit'] as num?)?.toInt() ?? 200,
    );
  }

  /// How many rows the source matches, ignoring its limit - what a `stat`
  /// count shows, and what `create_dynamic_screen` reports back so the
  /// model can tell a working query from one that matches nothing.
  static Future<int> countFor({
    required Database db,
    required UserCollectionRepository records,
    required Map<String, Object?> source,
    required Map<String, UserCollection> collections,
  }) async {
    final table = source['table'] as String;
    if (collections.containsKey(table)) {
      final all = await records.listRecords(table);
      return all.where((row) => ScreenSchema.rowMatches(row, source)).length;
    }
    final (where, args) = ScreenSchema.buildWhere(source);
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS value FROM $table'
      '${where == null ? '' : ' WHERE $where'}',
      args.isEmpty ? null : args,
    );
    return (rows.first['value'] as int?) ?? 0;
  }

  /// One aggregate over a whole source.
  ///
  /// SUM/AVG over no rows is null, which is a real answer ("nothing to
  /// total") and renders as a dash rather than a misleading zero.
  static Future<num?> aggregate({
    required Database db,
    required UserCollectionRepository records,
    required Map<String, Object?> source,
    required Map<String, Object?> component,
    required Map<String, UserCollection> collections,
  }) async {
    final table = source['table'] as String;
    final aggregateName = component['aggregate']?.toString() ?? 'count';
    final field = component['field']?.toString();

    if (collections.containsKey(table)) {
      final all = await records.listRecords(table);
      final matched =
          [for (final row in all) if (ScreenSchema.rowMatches(row, source)) row];
      if (aggregateName == 'count' || field == null) return matched.length;
      final numbers = [
        for (final row in matched)
          if (row[field] case final value?)
            value is num ? value : num.tryParse('$value'),
      ].whereType<num>().toList();
      if (numbers.isEmpty) return null;
      final sum = numbers.fold<num>(0, (a, b) => a + b);
      return aggregateName == 'avg' ? sum / numbers.length : sum;
    }

    final (where, args) = ScreenSchema.buildWhere(source);
    final expression = switch (aggregateName) {
      'sum' when field != null => 'SUM($field)',
      'avg' when field != null => 'AVG($field)',
      _ => 'COUNT(*)',
    };
    final rows = await db.rawQuery(
      'SELECT $expression AS value FROM $table'
      '${where == null ? '' : ' WHERE $where'}',
      args.isEmpty ? null : args,
    );
    return rows.isEmpty ? null : rows.first['value'] as num?;
  }
}
