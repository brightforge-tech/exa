import 'phone_bridge.dart';

/// Who a text or call is for, settled to one number.
class PhoneRecipient {
  const PhoneRecipient({required this.name, required this.number});

  /// What the user called them - a contact's name, or the number itself.
  final String name;

  /// Normalized number to send to / dial.
  final String number;
}

/// The outcome of turning "Mum" / "+44 7700 900123" / "Dr Patel (work)" into
/// a single number: either a [recipient], or a [failure] the model can act
/// on - which names the candidates, because "which one?" with no options is
/// a question the user cannot answer without opening their contacts.
class RecipientResolution {
  const RecipientResolution.found(PhoneRecipient this.recipient)
      : failure = null,
        candidates = const [];

  const RecipientResolution.failed(this.failure, {this.candidates = const []})
      : recipient = null;

  final PhoneRecipient? recipient;
  final String? failure;

  /// Contacts that matched when the match was not unique.
  final List<PhoneContact> candidates;

  bool get isFound => recipient != null;
}

/// Turns a recipient as the user said it into a number.
///
/// Pure decision logic over the bridge, kept out of the tools so the rules -
/// a typed number passes straight through; a name must match exactly one
/// contact; a contact with several numbers must have a clear default - can be
/// tested without a device. A message to the wrong person cannot be taken
/// back, so every ambiguity here is a refusal that lists the options, never
/// a guess.
class PhoneRecipientResolver {
  const PhoneRecipientResolver(this.bridge);

  final PhoneBridge bridge;

  /// Whether [text] is a phone number rather than a name: only digits, `+`,
  /// spaces, dots, dashes and parentheses, with at least five digits.
  static bool looksLikeNumber(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    if (!RegExp(r'^\+?[\d\s().-]+$').hasMatch(trimmed)) return false;
    return RegExp(r'\d').allMatches(trimmed).length >= 5;
  }

  /// Bare digits (with a leading `+` kept) - the off-device fallback when the
  /// phone's own normalizer is not available.
  static String bareDigits(String number) {
    final trimmed = number.trim();
    final digits = trimmed.replaceAll(RegExp(r'[^\d]'), '');
    return trimmed.startsWith('+') ? '+$digits' : digits;
  }

  Future<RecipientResolution> resolve(
    String to, {
    String? preferredLabel,
  }) async {
    final query = to.trim();
    if (query.isEmpty) {
      return const RecipientResolution.failed(
          'Say who this is for - a contact name or a phone number.');
    }
    if (looksLikeNumber(query)) {
      final normalized =
          await bridge.normalizeNumber(query) ?? bareDigits(query);
      return RecipientResolution.found(
          PhoneRecipient(name: query, number: normalized));
    }

    final permissions = await bridge.permissions();
    final contacts = await bridge.findContacts(query, limit: 8);
    if (contacts.isEmpty) {
      if (!permissions.contacts) {
        return RecipientResolution.failed(
            'Exa cannot look up "$query": it does not have permission to '
            'read contacts. The user can grant it in Settings > Phone '
            'access, or give you the phone number directly.');
      }
      return RecipientResolution.failed(
          'No contact named "$query" has a phone number. Ask the user for '
          'the number, or the name exactly as it is saved.');
    }

    // An exact name match beats a substring match: "Sam" should not be
    // ambiguous between Sam and Samantha when the user has a contact
    // called exactly Sam.
    final lower = query.toLowerCase();
    final exact = contacts
        .where((c) => c.name.trim().toLowerCase() == lower)
        .toList();
    final pool = exact.isNotEmpty ? exact : contacts;
    if (pool.length > 1) {
      return RecipientResolution.failed(
        'Several contacts match "$query": '
        '${pool.map((c) => c.name).join(', ')}. Ask the user which one '
        'they mean - a message to the wrong person cannot be taken back.',
        candidates: pool,
      );
    }
    final contact = pool.single;
    final number = _pickNumber(contact, preferredLabel);
    if (number == null) {
      return RecipientResolution.failed(
        '${contact.name} has several numbers: '
        '${contact.numbers.map((n) => '${n.label.isEmpty ? 'number' : n.label} '
            '${n.number}').join(', ')}. Ask the user which one, then pass '
        'that number as "to".',
        candidates: [contact],
      );
    }
    return RecipientResolution.found(
        PhoneRecipient(name: contact.name, number: number.normalized));
  }

  /// The one number to use, or null when the choice is genuinely open.
  static ContactNumber? _pickNumber(PhoneContact contact, String? preferred) {
    final numbers = contact.numbers;
    if (numbers.isEmpty) return null;
    if (numbers.length == 1) return numbers.single;
    if (preferred != null && preferred.trim().isNotEmpty) {
      final wanted = preferred.trim().toLowerCase();
      final labelled = numbers
          .where((n) => n.label.toLowerCase() == wanted)
          .toList();
      if (labelled.length == 1) return labelled.single;
    }
    final primary = numbers.where((n) => n.primary).toList();
    if (primary.length == 1) return primary.single;
    final mobile = numbers
        .where((n) => n.label.toLowerCase().contains('mobile'))
        .toList();
    if (mobile.length == 1) return mobile.single;
    return null;
  }
}
