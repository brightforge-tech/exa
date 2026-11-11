import 'package:exa_mobile/agent/security/capability_policy.dart';
import 'package:exa_mobile/agent/security/write_scope.dart';
import 'package:exa_mobile/agent/tools/tool_registry.dart';
import 'package:exa_mobile/data/database/app_database.dart';
import 'package:exa_mobile/data/repositories/behavior_repository.dart';
import 'package:exa_mobile/data/repositories/browser_context_repository.dart';
import 'package:exa_mobile/data/repositories/dynamic_screen_repository.dart';
import 'package:exa_mobile/data/repositories/email_repository.dart';
import 'package:exa_mobile/data/repositories/inbound_message_repository.dart';
import 'package:exa_mobile/data/repositories/job_repository.dart';
import 'package:exa_mobile/data/repositories/mail_account_repository.dart';
import 'package:exa_mobile/data/repositories/pending_calendar_repository.dart';
import 'package:exa_mobile/data/repositories/reminder_repository.dart';
import 'package:exa_mobile/data/repositories/schedule_repository.dart';
import 'package:exa_mobile/data/repositories/task_repository.dart';
import 'package:exa_mobile/data/repositories/tool_call_repository.dart';
import 'package:exa_mobile/services/background_jobs/job_runner.dart';
import 'package:exa_mobile/services/browser/browser_bridge.dart';
import 'package:exa_mobile/services/calendar/device_calendar_service.dart';
import 'package:exa_mobile/services/mail/mail_service.dart';
import 'package:exa_mobile/services/messaging/message_channels.dart';
import 'package:exa_mobile/services/notifications/notification_service.dart';
import 'package:exa_mobile/services/phone/phone_bridge.dart';
import 'package:exa_mobile/services/phone/phone_recipient.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A phone that records what it was asked to do.
class FakePhoneBridge extends PhoneBridge {
  FakePhoneBridge();

  List<PhoneContact> contacts = const [];
  PhonePermissions granted = const PhonePermissions(
      sms: true, call: true, contacts: true, telephony: true);
  bool interactive = true;
  bool locked = false;
  Set<String> liveReplies = {};
  String? directReplyFailure;
  String callStatus = 'placed';

  final sent = <({String number, String text})>[];
  final calls = <String>[];
  final composers = <({String? number, String text})>[];
  final notifications = <({String kind, String? number, String text})>[];
  final replies = <({String channel, String conversationId, String text})>[];

  @override
  Future<PhonePermissions> permissions() async => granted;

  @override
  Future<({bool interactive, bool locked})> deviceState() async =>
      (interactive: interactive, locked: locked);

  @override
  Future<String?> normalizeNumber(String number) async =>
      PhoneRecipientResolver.bareDigits(number);

  @override
  Future<List<PhoneContact>> findContacts(String query, {int limit = 10}) async {
    if (!granted.contacts) return const [];
    final needle = query.toLowerCase();
    return contacts
        .where((c) => c.name.toLowerCase().contains(needle))
        .take(limit)
        .toList();
  }

  @override
  Future<PhoneActionOutcome> sendSms({
    required String number,
    required String text,
  }) async {
    sent.add((number: number, text: text));
    return PhoneActionOutcome('sent', number: number, parts: 1);
  }

  @override
  Future<PhoneActionOutcome> placeCall(String number) async {
    calls.add(number);
    return PhoneActionOutcome(callStatus, number: number);
  }

  @override
  Future<PhoneActionOutcome> openWhatsApp({
    String? number,
    required String text,
    bool business = false,
  }) async {
    composers.add((number: number, text: text));
    return PhoneActionOutcome('composer_opened', number: number);
  }

  @override
  Future<PhoneActionOutcome> notifyPhoneAction({
    required String kind,
    String? number,
    String text = '',
    required String title,
    required String body,
  }) async {
    notifications.add((kind: kind, number: number, text: text));
    return const PhoneActionOutcome('notified');
  }

  @override
  Future<bool> canDirectReply({
    required String channel,
    required String conversationId,
  }) async =>
      liveReplies.contains('$channel|$conversationId');

  @override
  Future<String?> directReply({
    required String channel,
    required String conversationId,
    required String text,
  }) async {
    if (directReplyFailure != null) return directReplyFailure;
    replies.add((channel: channel, conversationId: conversationId, text: text));
    return null;
  }
}

PhoneContact contact(String name, List<(String, String, {bool primary})> numbers) =>
    PhoneContact(
      name: name,
      numbers: [
        for (final n in numbers)
          ContactNumber(
            number: n.$1,
            normalized: PhoneRecipientResolver.bareDigits(n.$1),
            label: n.$2,
            primary: n.primary,
          ),
      ],
    );

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('PhoneRecipientResolver', () {
    late FakePhoneBridge phone;
    late PhoneRecipientResolver resolver;

    setUp(() {
      phone = FakePhoneBridge();
      resolver = PhoneRecipientResolver(phone);
    });

    test('a typed number passes straight through, normalized', () async {
      final result = await resolver.resolve('+44 7700 900 123');
      expect(result.isFound, isTrue);
      expect(result.recipient!.number, '+447700900123');
      expect(result.recipient!.name, '+44 7700 900 123');
      expect(PhoneRecipientResolver.looksLikeNumber('Mum'), isFalse);
      expect(PhoneRecipientResolver.looksLikeNumber('(020) 7946-0958'), isTrue);
      // Too few digits to be a number: a house number is a name.
      expect(PhoneRecipientResolver.looksLikeNumber('42'), isFalse);
    });

    test('an exact name match beats a substring match', () async {
      phone.contacts = [
        contact('Sam', [('07700 900001', 'Mobile', primary: false)]),
        contact('Samantha', [('07700 900002', 'Mobile', primary: false)]),
      ];
      final result = await resolver.resolve('sam');
      expect(result.isFound, isTrue);
      expect(result.recipient!.name, 'Sam');
      expect(result.recipient!.number, '07700900001');
    });

    test('several contacts is a refusal that names them, not a guess',
        () async {
      phone.contacts = [
        contact('Alex Reed', [('1', 'Mobile', primary: false)]),
        contact('Alex Stone', [('2', 'Mobile', primary: false)]),
      ];
      final result = await resolver.resolve('Alex');
      expect(result.isFound, isFalse);
      expect(result.failure, contains('Alex Reed'));
      expect(result.failure, contains('Alex Stone'));
      expect(result.candidates, hasLength(2));
    });

    test('several numbers: primary, then Mobile, then the asked-for label',
        () async {
      phone.contacts = [
        contact('Dad', [
          ('01onehome', 'Home', primary: false),
          ('07700 900003', 'Mobile', primary: false),
        ]),
      ];
      expect((await resolver.resolve('Dad')).recipient!.number, '07700900003');

      phone.contacts = [
        contact('Dad', [
          ('020 1111', 'Home', primary: true),
          ('07700 900003', 'Mobile', primary: false),
        ]),
      ];
      expect((await resolver.resolve('Dad')).recipient!.number, '0201111');

      expect(
          (await resolver.resolve('Dad', preferredLabel: 'mobile'))
              .recipient!
              .number,
          '07700900003');
    });

    test('two numbers and no way to choose is a refusal listing them',
        () async {
      phone.contacts = [
        contact('Office', [
          ('020 1111', 'Work', primary: false),
          ('020 2222', 'Other', primary: false),
        ]),
      ];
      final result = await resolver.resolve('Office');
      expect(result.isFound, isFalse);
      expect(result.failure, contains('020 1111'));
      expect(result.failure, contains('020 2222'));
    });

    test('unknown name, and a missing contacts permission, say so', () async {
      expect((await resolver.resolve('Nobody')).failure,
          contains('No contact named "Nobody"'));
      phone.granted = const PhonePermissions(sms: true, call: true);
      expect((await resolver.resolve('Nobody')).failure,
          contains('permission to read contacts'));
    });
  });

  group('phone tools', () {
    late AppDatabase database;
    late ToolRegistry registry;
    late FakePhoneBridge phone;
    late InboundMessageRepository chatMessages;

    setUp(() async {
      database = AppDatabase();
      await database.open(overridePath: inMemoryDatabasePath);
      phone = FakePhoneBridge()
        ..contacts = [
          contact('Mum', [('07700 900111', 'Mobile', primary: false)]),
          contact('Alice', [('07700 900222', 'Mobile', primary: false)]),
        ];
      chatMessages = InboundMessageRepository(database);
      final notifications = NotificationService();
      final mailAccounts = MailAccountRepository(database);
      final emails = EmailRepository(database);
      final schedule = ScheduleRepository(database);
      registry = ToolRegistry(
        tasks: TaskRepository(database),
        reminders: ReminderRepository(database),
        schedule: schedule,
        behaviors: BehaviorRepository(database),
        screens: DynamicScreenRepository(database),
        toolCalls: ToolCallRepository(database),
        notifications: notifications,
        database: database,
        jobs: JobRepository(database),
        jobRunner: JobRunner(database: database, notifications: notifications),
        browserContext: BrowserContextRepository(database),
        emails: emails,
        browserBridge: BrowserBridge(),
        mailAccounts: mailAccounts,
        mail: MailService(accounts: mailAccounts, emails: emails),
        deviceCalendar: DeviceCalendarService(schedule: schedule),
        pendingCalendar: PendingCalendarRepository(database),
        chatMessages: chatMessages,
        phoneBridge: phone,
      );
    });

    tearDown(() => database.close());

    CapabilityContext unattended({Set<String> grants = const {}}) {
      final permissions = JobPermissions(outboundGrants: grants);
      return CapabilityContext(
        runMode: AgentRunMode.unattended,
        jobPermissions: permissions,
        writeLedger: WriteScopeLedger(WriteScope.forJob(permissions.encode())),
      );
    }

    test('are registered in the phone domain, classified, and confirmed',
        () {
      for (final name in ['send_sms', 'place_call', 'send_whatsapp']) {
        expect(registry[name], isNotNull, reason: name);
        expect(registry.domainOf(name), 'phone', reason: name);
        expect(registry[name]!.requiresConfirmation, isTrue, reason: name);
        expect(CapabilityGate.capabilityOf(name), ToolCapability.outbound,
            reason: name);
      }
      expect(registry['find_contact']!.requiresConfirmation, isFalse);
      expect(CapabilityGate.capabilityOf('find_contact'), ToolCapability.read);
    });

    test('find_contact returns numbers with labels', () async {
      final result = await registry.execute('find_contact', {'name': 'mum'});
      expect(result.success, isTrue);
      final data = result.data as Map;
      expect(data['count'], 1);
      final numbers = (data['contacts'] as List).first['numbers'] as List;
      expect(numbers.first['label'], 'Mobile');
      expect(numbers.first['normalized'], '07700900111');
    });

    test('send_sms resolves the contact, sends, and records the message',
        () async {
      final result = await registry.execute(
          'send_sms', {'to': 'Mum', 'text': 'Running late, sorry!'});
      expect(result.success, isTrue, reason: result.error);
      expect((result.data as Map)['sent'], isTrue);
      expect(phone.sent.single.number, '07700900111');
      expect(phone.sent.single.text, 'Running late, sorry!');
      // Visible to the next digest and the Messages screen as "You".
      final recorded = await chatMessages.recent(channel: MessageChannels.sms);
      expect(recorded, hasLength(1));
      expect(recorded.single.sender, 'You');
      expect(recorded.single.conversationTitle, 'Mum');
    });

    test('send_sms refuses an ambiguous name without sending anything',
        () async {
      phone.contacts = [
        contact('Alex Reed', [('1', 'Mobile', primary: false)]),
        contact('Alex Stone', [('2', 'Mobile', primary: false)]),
      ];
      final result =
          await registry.execute('send_sms', {'to': 'Alex', 'text': 'hi'});
      expect(result.success, isFalse);
      expect(result.error, contains('Alex Reed'));
      expect(phone.sent, isEmpty);
    });

    test('send_sms in a scheduled run needs an outbound grant', () async {
      final denied = await registry.execute(
        'send_sms',
        {'to': 'Mum', 'text': 'Have a good weekend'},
        capabilities: unattended(),
      );
      expect(denied.wasDenied, isTrue);
      expect(denied.error, contains('outbound grant'));
      expect(phone.sent, isEmpty);

      final granted = await registry.execute(
        'send_sms',
        {'to': 'Mum', 'text': 'Have a good weekend'},
        capabilities: unattended(grants: {'send_sms'}),
      );
      expect(granted.success, isTrue, reason: granted.error);
      expect(phone.sent.single.text, 'Have a good weekend');
    });

    test('place_call dials interactively, and reports a dialler hand-off',
        () async {
      final placed = await registry.execute('place_call', {'to': 'Mum'});
      expect(placed.success, isTrue, reason: placed.error);
      expect((placed.data as Map)['called'], isTrue);
      expect(phone.calls, ['07700900111']);

      phone.callStatus = 'dialer_opened';
      final handed = await registry.execute('place_call', {'to': 'Mum'});
      expect((handed.data as Map)['called'], isFalse);
      expect((handed.data as Map)['note'], contains('dialler'));
    });

    test('a scheduled call on a locked or dark phone becomes a tap-to-call',
        () async {
      phone
        ..interactive = false
        ..locked = true;
      final result = await registry.execute(
        'place_call',
        {'to': 'Mum'},
        capabilities: unattended(grants: {'place_call'}),
      );
      expect(result.success, isTrue, reason: result.error);
      final data = result.data as Map;
      expect(data['called'], isFalse);
      expect(data['notified'], isTrue);
      expect(phone.calls, isEmpty);
      expect(phone.notifications.single.kind, 'call');
      expect(phone.notifications.single.number, '07700900111');

      // Screen on and unlocked: the granted job dials.
      phone
        ..interactive = true
        ..locked = false;
      final dialled = await registry.execute(
        'place_call',
        {'to': 'Mum'},
        capabilities: unattended(grants: {'place_call'}),
      );
      expect((dialled.data as Map)['called'], isTrue);
      expect(phone.calls, ['07700900111']);
    });

    test('send_whatsapp with no live chat opens the composer and says so',
        () async {
      final result = await registry
          .execute('send_whatsapp', {'to': 'Alice', 'text': 'On my way'});
      expect(result.success, isTrue, reason: result.error);
      final data = result.data as Map;
      expect(data['sent'], isFalse);
      expect(data['composer_opened'], isTrue);
      expect(data['note'], contains('taps Send'));
      expect(phone.composers.single.number, '07700900222');
      expect(phone.composers.single.text, 'On my way');
      expect(phone.replies, isEmpty);
    });

    test('send_whatsapp uses the chat reply when the chat is live in the shade',
        () async {
      await chatMessages.recordOutgoing(
        channel: MessageChannels.whatsapp,
        conversationId: 'alice',
        conversationTitle: 'Alice',
        body: 'earlier',
      );
      phone.liveReplies = {'whatsapp|alice'};
      final result = await registry
          .execute('send_whatsapp', {'to': 'Alice', 'text': 'On my way'});
      expect(result.success, isTrue, reason: result.error);
      final data = result.data as Map;
      expect(data['sent'], isTrue);
      expect(data['via'], 'chat_reply');
      expect(phone.replies.single.conversationId, 'alice');
      expect(phone.composers, isEmpty);
      final recorded =
          await chatMessages.recent(channel: MessageChannels.whatsapp);
      expect(recorded.first.body, 'On my way');
      expect(recorded.first.sender, 'You');
    });

    test('a scheduled WhatsApp with no live reply becomes a tap-to-send',
        () async {
      final result = await registry.execute(
        'send_whatsapp',
        {'to': 'Alice', 'text': 'Happy Friday'},
        capabilities: unattended(grants: {'send_whatsapp'}),
      );
      expect(result.success, isTrue, reason: result.error);
      final data = result.data as Map;
      expect(data['sent'], isFalse);
      expect(data['notified'], isTrue);
      expect(phone.notifications.single.kind, 'whatsapp');
      expect(phone.notifications.single.text, 'Happy Friday');
      expect(phone.composers, isEmpty,
          reason: 'nobody is there to use an open composer');
    });

    test('a grant never widens a job beyond the granted tool', () async {
      // Granted send_sms, tried to WhatsApp: still refused.
      final result = await registry.execute(
        'send_whatsapp',
        {'to': 'Alice', 'text': 'hi'},
        capabilities: unattended(grants: {'send_sms'}),
      );
      expect(result.wasDenied, isTrue);
      expect(phone.notifications, isEmpty);
      expect(phone.composers, isEmpty);
    });
  });
}
