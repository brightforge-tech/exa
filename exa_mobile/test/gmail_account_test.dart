import 'package:exa_mobile/data/database/app_database.dart';
import 'package:exa_mobile/data/repositories/email_repository.dart';
import 'package:exa_mobile/data/repositories/mail_account_repository.dart';
import 'package:exa_mobile/services/mail/gmail_auth_service.dart';
import 'package:exa_mobile/services/mail/mail_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      null,
    );
  });

  late AppDatabase database;

  setUp(() async {
    database = AppDatabase();
    await database.open(overridePath: inMemoryDatabasePath);
  });

  tearDown(() => database.close());

  test('createGmail uses Gmail servers, XOAUTH2 auth, and can send', () async {
    final repo = MailAccountRepository(database);
    final account = await repo.createGmail(
      emailAddress: 'exa.user@gmail.example',
      displayName: 'Nick',
    );
    expect(account.authType, MailAccount.authGmail);
    expect(account.isGmail, isTrue);
    expect(account.imapHost, 'imap.gmail.com');
    expect(account.imapPort, 993);
    expect(account.smtpHost, 'smtp.gmail.com');
    expect(account.smtpPort, 465);
    expect(account.username, 'exa.user@gmail.example');
    expect(account.canSend, isTrue,
        reason: 'Gmail sign-in configures sending automatically');
    expect(account.syncEnabled, isTrue);

    // Round-trips through the database with its auth type intact.
    final loaded = await repo.getById(account.id);
    expect(loaded!.authType, MailAccount.authGmail);
  });

  test('connecting the same Gmail address twice reuses the account',
      () async {
    final repo = MailAccountRepository(database);
    final first = await repo.createGmail(emailAddress: 'exa.user@gmail.example');
    final second = await repo.createGmail(emailAddress: 'Exa.User@Gmail.Example');
    expect(second.id, first.id);
    expect(await repo.listAll(), hasLength(1));
  });

  test('manual accounts still default to password auth', () async {
    final repo = MailAccountRepository(database);
    final account = await repo.create(
      displayName: 'Work',
      emailAddress: 'me@example.com',
      username: 'me@example.com',
      password: 'app-password',
      imapHost: 'imap.example.com',
    );
    expect(account.authType, MailAccount.authPassword);
    expect(account.isGmail, isFalse);
  });

  test('gmail sync without a Google session records a friendly error '
      'instead of throwing', () async {
    final accounts = MailAccountRepository(database);
    final account = await accounts.createGmail(
      emailAddress: 'exa.user@gmail.example',
    );
    final mail = MailService(
      accounts: accounts,
      emails: EmailRepository(database),
      // Real service; in the test environment the Google sign-in plugin is
      // unavailable, which is exactly the failure path being verified.
      gmailAuth: GmailAuthService(),
    );

    final result = await mail.syncAccount(account);
    expect(result.error, isNotNull);
    expect(result.added, 0);

    // The failure is recorded on the account for the accounts screen.
    final after = await accounts.getById(account.id);
    expect(after!.lastError, isNotNull);
  });
}
