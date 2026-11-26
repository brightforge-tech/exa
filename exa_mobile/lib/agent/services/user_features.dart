import 'dart:convert';

import '../../data/models/dynamic_screen.dart';
import '../../data/models/user_collection.dart';
import '../../data/repositories/dynamic_screen_repository.dart';
import '../../data/repositories/user_collection_repository.dart';

/// One feature Exa built for the user: a collection of records and the
/// screens that show it.
class UserFeature {
  const UserFeature({
    required this.collection,
    required this.recordCount,
    this.screens = const [],
  });

  final UserCollection collection;
  final int recordCount;

  /// Saved screens whose schema reads this collection.
  final List<DynamicScreen> screens;

  String get name => collection.name;
  String get title => collection.title;
}

/// What Exa has built for this user, so a request can refer to it by name.
///
/// Without this, every turn started with no idea a "notes" feature existed.
/// "Save this as a note" read as a request to keep some text, and the rule
/// for keeping text is write_file - so the note went to Files, and the
/// notes screen the user had asked Exa to build sat empty. The collections
/// and screens are facts in the database; this puts them in front of the
/// model (in the per-turn context, so the cached system prompt is not
/// rewritten every time a record is added) and tells the orchestrator when
/// a request names one, so the tools that write to it are available.
class UserFeatureCatalog {
  const UserFeatureCatalog(this.features);

  static const empty = UserFeatureCatalog([]);

  final List<UserFeature> features;

  bool get isEmpty => features.isEmpty;

  /// The most features named in the context block; a user with more than
  /// this has the rest reachable through list_collections.
  static const maxListed = 12;

  /// The record-writing tools a request naming a feature needs.
  static const recordTools = {
    'list_collections',
    'list_records',
    'add_record',
    'update_record',
    'delete_record',
    'open_screen',
  };

  /// Never throws: a catalogue that cannot be read is a turn that does not
  /// know about the user's features, as before - not a failed turn.
  static Future<UserFeatureCatalog> load({
    required UserCollectionRepository collections,
    required DynamicScreenRepository screens,
  }) async {
    try {
      final all = await collections.listAll();
      if (all.isEmpty) return empty;
      final savedScreens = [
        for (final screen in await screens.listAll())
          if (screen.isSaved) screen,
      ];
      final features = <UserFeature>[];
      for (final collection in all) {
        features.add(UserFeature(
          collection: collection,
          recordCount: await collections.countRecords(collection.name),
          screens: [
            for (final screen in savedScreens)
              if (_readsCollection(screen, collection.name)) screen,
          ],
        ));
      }
      return UserFeatureCatalog(features);
    } catch (_) {
      return empty;
    }
  }

  static bool _readsCollection(DynamicScreen screen, String collection) {
    try {
      return jsonEncode(screen.schema).contains('"$collection"');
    } catch (_) {
      return false;
    }
  }

  /// The features [request] refers to: by collection name or title, in the
  /// singular or the plural ("a note" finds "notes", "my expense log" finds
  /// "Expense log"), or by the title of one of its screens.
  List<UserFeature> mentionedIn(String request) {
    final words = _words(request);
    if (words.isEmpty) return const [];
    final text = ' ${words.join(' ')} ';
    return [
      for (final feature in features)
        if (_names(feature).any((name) => _mentions(text, words, name)))
          feature,
    ];
  }

  static Iterable<String> _names(UserFeature feature) sync* {
    yield feature.name.replaceAll('_', ' ');
    yield feature.title;
    for (final screen in feature.screens) {
      yield screen.title;
    }
  }

  static bool _mentions(String text, List<String> words, String name) {
    final parts = _words(name);
    if (parts.isEmpty) return false;
    // A multi-word name must appear as a phrase; its last word may be
    // singular or plural either way round.
    final last = parts.last;
    final variants = {last, _singular(last), '${_singular(last)}s'};
    for (final variant in variants) {
      final phrase = [...parts.take(parts.length - 1), variant].join(' ');
      if (phrase.length < 3) continue;
      if (text.contains(' $phrase ')) return true;
    }
    return false;
  }

  static String _singular(String word) {
    if (word.length > 4 && word.endsWith('ies')) {
      return '${word.substring(0, word.length - 3)}y';
    }
    if (word.length > 3 && word.endsWith('s') && !word.endsWith('ss')) {
      return word.substring(0, word.length - 1);
    }
    return word;
  }

  static List<String> _words(String text) => text
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((word) => word.isNotEmpty)
      .toList();

  /// The block placed in the turn context. Empty when nothing was built.
  String describe({List<UserFeature> mentioned = const []}) {
    if (features.isEmpty) return '';
    final buffer = StringBuffer()
      ..writeln('Features you built for the user (their own data, kept in '
          'collections - use these before anything else when a request is '
          'about one):');
    for (final feature in features.take(maxListed)) {
      final fields = [
        for (final field in feature.collection.fields) field.name,
      ].join(', ');
      final screens = [
        for (final screen in feature.screens) '"${screen.title}"',
      ];
      buffer.writeln('- ${feature.title} (collection "${feature.name}"; '
          'fields: $fields; ${feature.recordCount} '
          '${feature.recordCount == 1 ? 'entry' : 'entries'}'
          '${screens.isEmpty ? '' : '; screen ${screens.join(', ')}'})');
    }
    if (features.length > maxListed) {
      buffer.writeln('- ...and ${features.length - maxListed} more '
          '(list_collections names them all)');
    }
    if (mentioned.isNotEmpty) {
      final names = [for (final f in mentioned) '"${f.name}"'].join(', ');
      buffer.writeln('This request refers to $names: read or change it with '
          'list_records / add_record / update_record on that collection - '
          'not write_file, a task or a reminder - and say it is in '
          '${mentioned.first.title}.');
    }
    return buffer.toString().trim();
  }
}
