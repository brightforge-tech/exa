import 'dart:convert';

/// One field of an agent-defined collection.
///
/// Types mirror the form inputs a dynamic screen can render, so a collection
/// is by construction something a generated screen can both edit and show:
/// `text`, `multiline`, `number`, `datetime`, `select`.
class CollectionField {
  static const allowedTypes = [
    'text',
    'multiline',
    'number',
    'datetime',
    'select',
  ];

  final String name;
  final String type;

  /// Allowed values, for `select` fields only.
  final List<String> options;
  final bool required;

  const CollectionField({
    required this.name,
    this.type = 'text',
    this.options = const [],
    this.required = false,
  });

  Map<String, Object?> toJson() => {
        'name': name,
        'type': type,
        if (options.isNotEmpty) 'options': options,
        if (required) 'required': true,
      };

  factory CollectionField.fromJson(Map<String, Object?> json) =>
      CollectionField(
        name: json['name'] as String,
        type: json['type'] as String? ?? 'text',
        options: (json['options'] as List? ?? const [])
            .map((option) => option.toString())
            .toList(),
        required: json['required'] == true,
      );
}

/// An agent-defined data collection: the "table" behind a feature the agent
/// built (notes, an expense log, a habit tracker).
///
/// Collections are rows in `user_collections`, never real SQL tables - the
/// agent can define as many as its features need without ever running DDL,
/// and everything it defines stays inside the same allowlisted query path
/// dynamic screens already use.
class UserCollection {
  /// Field names every record carries implicitly; a definition may not
  /// redeclare them.
  static const reservedFieldNames = ['id', 'collection', 'created_at',
      'updated_at'];

  static const maxFields = 12;

  /// Lowercase snake_case, starting with a letter - the same shape as a
  /// table name, because screens reference collections exactly like tables.
  static final namePattern = RegExp(r'^[a-z][a-z0-9_]{0,29}$');

  final String name;
  final String title;
  final List<CollectionField> fields;
  final DateTime createdAt;
  final DateTime updatedAt;

  const UserCollection({
    required this.name,
    required this.title,
    required this.fields,
    required this.createdAt,
    required this.updatedAt,
  });

  /// The queryable columns of this collection, as a screen schema sees
  /// them: the declared fields plus the implicit record columns.
  List<String> get columns => [
        'id',
        for (final field in fields) field.name,
        'created_at',
        'updated_at',
      ];

  /// Declared fields whose values are numbers - what a `sum`/`avg` stat may
  /// aggregate.
  List<String> get numericColumns => [
        for (final field in fields)
          if (field.type == 'number') field.name,
      ];

  /// Columns holding datetimes (declared `datetime` fields plus the record
  /// timestamps) - what a `calendar` component may group by.
  List<String> get dateColumns => [
        for (final field in fields)
          if (field.type == 'datetime') field.name,
        'created_at',
        'updated_at',
      ];

  CollectionField? fieldNamed(String name) {
    for (final field in fields) {
      if (field.name == name) return field;
    }
    return null;
  }

  Map<String, Object?> toRow() => {
        'name': name,
        'title': title,
        'fields_json': jsonEncode([for (final f in fields) f.toJson()]),
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory UserCollection.fromRow(Map<String, Object?> row) => UserCollection(
        name: row['name'] as String,
        title: row['title'] as String? ?? row['name'] as String,
        fields: [
          for (final raw in jsonDecode(row['fields_json'] as String) as List)
            CollectionField.fromJson((raw as Map).cast<String, Object?>()),
        ],
        createdAt: DateTime.tryParse(row['created_at'] as String? ?? '') ??
            DateTime.now(),
        updatedAt: DateTime.tryParse(row['updated_at'] as String? ?? '') ??
            DateTime.now(),
      );

  /// Compact form handed to the agent as a tool result.
  Map<String, Object?> toAgentJson() => {
        'collection': name,
        'title': title,
        'fields': [for (final field in fields) field.toJson()],
      };
}
