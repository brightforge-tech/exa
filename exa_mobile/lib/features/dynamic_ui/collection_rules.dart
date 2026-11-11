import '../../data/models/user_collection.dart';
import 'screen_schema.dart';

/// Validation for collection definitions and record values.
///
/// Sits beside [ScreenSchema] rather than in the model because it needs the
/// built-in table names (a collection may not shadow one) - and because it
/// serves the same purpose: reject early with an error that names the valid
/// values, so the model fixes its next attempt instead of shipping a broken
/// feature.
class CollectionRules {
  CollectionRules._();

  /// Returns an error string, or null when the definition is valid.
  static String? validateDefinition({
    required String name,
    required List<CollectionField> fields,
  }) {
    if (!UserCollection.namePattern.hasMatch(name)) {
      return "Collection name '$name' must be lowercase snake_case "
          '(e.g. notes, expense_log), max 30 chars';
    }
    if (ScreenSchema.allowedTables.containsKey(name)) {
      return "'$name' is a built-in table and cannot be redefined";
    }
    if (fields.isEmpty) {
      return 'A collection needs at least one field';
    }
    if (fields.length > UserCollection.maxFields) {
      return 'A collection may have at most ${UserCollection.maxFields} '
          'fields';
    }
    final seen = <String>{};
    for (final field in fields) {
      if (!UserCollection.namePattern.hasMatch(field.name)) {
        return "Field name '${field.name}' must be lowercase snake_case";
      }
      if (UserCollection.reservedFieldNames.contains(field.name)) {
        return "'${field.name}' is a reserved column every record already "
            'has - do not declare it';
      }
      if (!seen.add(field.name)) {
        return "Field '${field.name}' is declared twice";
      }
      if (!CollectionField.allowedTypes.contains(field.type)) {
        return "Field '${field.name}' has unknown type '${field.type}'. "
            'Allowed: ${CollectionField.allowedTypes.join(', ')}';
      }
      if (field.type == 'select' && field.options.isEmpty) {
        return "Select field '${field.name}' needs an 'options' array";
      }
    }
    return null;
  }

  /// Checks and coerces record [values] against [collection]'s fields.
  ///
  /// Returns (coerced values, null) on success or (null, error) on failure.
  /// With [partial] true (updates), required fields may be absent - but a
  /// value that IS present must still be valid.
  static (Map<String, Object?>?, String?) coerceValues({
    required UserCollection collection,
    required Map<String, Object?> values,
    bool partial = false,
  }) {
    final coerced = <String, Object?>{};
    for (final entry in values.entries) {
      final field = collection.fieldNamed(entry.key);
      if (field == null) {
        return (
          null,
          "'${entry.key}' is not a field of ${collection.name}. Fields: "
              '${collection.fields.map((f) => f.name).join(', ')}'
        );
      }
      final value = entry.value;
      if (value == null) {
        coerced[field.name] = null;
        continue;
      }
      switch (field.type) {
        case 'number':
          final number = value is num ? value : num.tryParse('$value');
          if (number == null) {
            return (null, "'${field.name}' must be a number, got '$value'");
          }
          coerced[field.name] = number;
        case 'datetime':
          final text = '$value';
          if (DateTime.tryParse(text) == null) {
            return (
              null,
              "'${field.name}' must be an ISO 8601 datetime, got '$value'"
            );
          }
          coerced[field.name] = text;
        case 'select':
          final text = '$value';
          if (!field.options.contains(text)) {
            return (
              null,
              "'${field.name}' must be one of: ${field.options.join(', ')} "
                  "- got '$value'"
            );
          }
          coerced[field.name] = text;
        default:
          coerced[field.name] = '$value';
      }
    }
    if (!partial) {
      for (final field in collection.fields) {
        final value = coerced[field.name];
        if (field.required &&
            (value == null || value.toString().trim().isEmpty)) {
          return (null, "Required field '${field.name}' is missing");
        }
      }
    }
    return (coerced, null);
  }
}
