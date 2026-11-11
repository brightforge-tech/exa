import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One phone number on a contact card.
class ContactNumber {
  const ContactNumber({
    required this.number,
    required this.normalized,
    this.label = '',
    this.primary = false,
  });

  /// As written on the card ("07700 900123").
  final String number;

  /// E.164 when the number can be read that way ("+447700900123"), else the
  /// bare digits - what every send/dial call actually uses.
  final String normalized;

  /// "Mobile", "Home", "Work", or a custom label.
  final String label;

  /// The card's default number, when it has one marked.
  final bool primary;

  static ContactNumber fromMap(Map<Object?, Object?> map) => ContactNumber(
        number: map['number'] as String? ?? '',
        normalized: map['normalized'] as String? ?? map['number'] as String? ?? '',
        label: map['label'] as String? ?? '',
        primary: map['primary'] == true,
      );

  Map<String, Object?> toJson() => {
        'number': number,
        'normalized': normalized,
        if (label.isNotEmpty) 'label': label,
        if (primary) 'primary': true,
      };
}

/// A contact with at least one phone number.
class PhoneContact {
  const PhoneContact({required this.name, required this.numbers});

  final String name;
  final List<ContactNumber> numbers;

  static PhoneContact fromMap(Map<Object?, Object?> map) => PhoneContact(
        name: map['name'] as String? ?? '',
        numbers: (map['numbers'] as List?)
                ?.whereType<Map<Object?, Object?>>()
                .map(ContactNumber.fromMap)
                .toList() ??
            const [],
      );

  Map<String, Object?> toJson() => {
        'name': name,
        'numbers': [for (final n in numbers) n.toJson()],
      };
}

/// What the phone did with a send / call / hand-off request.
///
/// The vocabulary is deliberately narrow and is carried straight into tool
/// results: `sent` and `placed` are the only two words for "done". Anything
/// else means the user still has something to do, and a tool must say so
/// rather than round it up - a WhatsApp composer left open with the text
/// typed in is not a message that went out.
class PhoneActionOutcome {
  const PhoneActionOutcome(this.status, {this.number, this.error, this.parts});

  /// `sent`, `placed`, `dialer_opened`, `composer_opened`, `notified`,
  /// `failed`, or `unavailable` (no phone plugin - tests, desktop).
  final String status;
  final String? number;
  final String? error;

  /// For SMS: how many segments the text took.
  final int? parts;

  bool get isDone => status == 'sent' || status == 'placed';
  bool get isFailure => status == 'failed' || status == 'unavailable';

  static const unavailable = PhoneActionOutcome(
    'unavailable',
    error: 'Phone features are only available on the device.',
  );

  static PhoneActionOutcome fromMap(Map<Object?, Object?>? map) {
    if (map == null) return unavailable;
    return PhoneActionOutcome(
      map['status'] as String? ?? 'failed',
      number: map['number'] as String?,
      error: map['error'] as String?,
      parts: map['parts'] as int?,
    );
  }
}

/// Runtime permissions the phone tools depend on.
class PhonePermissions {
  const PhonePermissions({
    this.sms = false,
    this.call = false,
    this.contacts = false,
    this.telephony = false,
  });

  final bool sms;
  final bool call;
  final bool contacts;

  /// Whether the device has a radio at all (a tablet does not).
  final bool telephony;

  static PhonePermissions fromMap(Map<Object?, Object?>? map) => PhonePermissions(
        sms: map?['sms'] == true,
        call: map?['call'] == true,
        contacts: map?['contacts'] == true,
        telephony: map?['telephony'] == true,
      );
}

/// Bridge to the `exa_phone` plugin (`ExaPhonePlugin.kt`).
///
/// Unlike `MessagingBridge`, this channel is registered by a *plugin*, so it
/// is live in every engine - the app, the overlay, and the background isolates
/// that run scheduled jobs. That is what lets a job created with an outbound
/// grant send a text at 17:00 on a Friday with nobody holding the phone.
///
/// Every method degrades to a safe answer off-Android rather than throwing:
/// tests and desktop runs have no plugin, and the tools read the outcome
/// rather than catching exceptions. Methods are non-final so tests can
/// subclass this with a fake.
class PhoneBridge {
  const PhoneBridge();

  static const _channel = MethodChannel('com.brightforge.exa/phone');

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<PhonePermissions> permissions() async =>
      PhonePermissions.fromMap(await _call<Map<Object?, Object?>>('permissions'));

  /// `interactive` (screen on) and `locked` (keyguard up). A scheduled call
  /// only dials outright when someone is plausibly looking at the phone.
  Future<({bool interactive, bool locked})> deviceState() async {
    final map = await _call<Map<Object?, Object?>>('deviceState');
    return (
      interactive: map?['interactive'] != false,
      locked: map?['locked'] == true,
    );
  }

  /// E.164 for anything the phone can read as a number; null when it cannot
  /// (or off-device, where the caller falls back to its own digits).
  Future<String?> normalizeNumber(String number) =>
      _call<String>('normalizeNumber', {'number': number});

  /// Contacts whose name contains [query], with their numbers. Throws
  /// nothing: a missing permission comes back as an empty list and the
  /// caller checks [permissions] to explain why.
  Future<List<PhoneContact>> findContacts(String query, {int limit = 10}) async {
    final raw = await _call<List<Object?>>(
        'findContacts', {'query': query, 'limit': limit});
    return raw
            ?.whereType<Map<Object?, Object?>>()
            .map(PhoneContact.fromMap)
            .toList() ??
        const [];
  }

  Future<PhoneActionOutcome> sendSms({
    required String number,
    required String text,
  }) async =>
      PhoneActionOutcome.fromMap(await _call<Map<Object?, Object?>>(
          'sendSms', {'number': number, 'text': text}));

  Future<PhoneActionOutcome> placeCall(String number) async =>
      PhoneActionOutcome.fromMap(
          await _call<Map<Object?, Object?>>('placeCall', {'number': number}));

  /// Opens WhatsApp on the chat for [number] with [text] typed in. The user
  /// presses Send; the outcome is `composer_opened`, never `sent`.
  Future<PhoneActionOutcome> openWhatsApp({
    String? number,
    required String text,
    bool business = false,
  }) async =>
      PhoneActionOutcome.fromMap(await _call<Map<Object?, Object?>>(
        'openWhatsApp',
        {'number': number, 'text': text, 'business': business},
      ));

  Future<bool> isInstalled(String package) async =>
      await _call<bool>('isInstalled', {'package': package}) ?? false;

  /// Posts a one-tap notification that performs the action (`call` or
  /// `whatsapp`) - the form a scheduled action takes when nobody is there.
  Future<PhoneActionOutcome> notifyPhoneAction({
    required String kind,
    String? number,
    String text = '',
    required String title,
    required String body,
  }) async =>
      PhoneActionOutcome.fromMap(await _call<Map<Object?, Object?>>(
        'notifyPhoneAction',
        {
          'kind': kind,
          'number': number,
          'text': text,
          'title': title,
          'body': body,
        },
      ));

  /// Whether a chat can be answered right now through its own notification
  /// reply action (the message is still unread in the shade).
  Future<bool> canDirectReply({
    required String channel,
    required String conversationId,
  }) async =>
      await _call<bool>('canDirectReply', {
        'channel': channel,
        'conversation_id': conversationId,
      }) ??
      false;

  /// Sends [text] through the chat's notification reply action. Null on
  /// success, or the reason it was not delivered (same inverted convention
  /// as `MessagingBridge.sendReply`, for the same reason).
  Future<String?> directReply({
    required String channel,
    required String conversationId,
    required String text,
  }) async {
    try {
      return await _channel.invokeMethod<String>('directReply', {
        'channel': channel,
        'conversation_id': conversationId,
        'text': text,
      });
    } on MissingPluginException {
      return 'Replying through chat notifications is only available on the '
          'device.';
    } on PlatformException catch (e) {
      return e.message ?? 'The reply could not be sent.';
    }
  }
}

final phoneBridgeProvider = Provider<PhoneBridge>((ref) => const PhoneBridge());
