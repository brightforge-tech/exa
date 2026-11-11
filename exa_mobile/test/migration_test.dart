import 'dart:io';

import 'package:exa_mobile/agent/memory/memory_repository.dart';
import 'package:exa_mobile/agent/memory/models/agent_memory.dart';
import 'package:exa_mobile/data/database/app_database.dart';
import 'package:exa_mobile/data/models/day_plan_entry.dart';
import 'package:exa_mobile/data/models/inbound_media.dart';
import 'package:exa_mobile/data/models/inbound_message.dart';
import 'package:exa_mobile/data/repositories/day_plan_repository.dart';
import 'package:exa_mobile/data/repositories/inbound_media_repository.dart';
import 'package:exa_mobile/data/repositories/inbound_message_repository.dart';
import 'package:exa_mobile/services/messaging/message_channels.dart';
import 'package:exa_mobile/data/repositories/behavior_repository.dart';
import 'package:exa_mobile/data/repositories/diagnostics_repository.dart';
import 'package:exa_mobile/data/repositories/job_repository.dart';
import 'package:exa_mobile/data/repositories/mail_account_repository.dart';
import 'package:exa_mobile/data/repositories/schedule_repository.dart';
import 'package:exa_mobile/data/models/user_collection.dart';
import 'package:exa_mobile/data/repositories/task_repository.dart';
import 'package:exa_mobile/data/repositories/user_collection_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('v7 -> v8 upgrade adds lead_time_minutes and keeps existing rows',
      () async {
    final dir = await Directory.systemTemp.createTemp('exa_migration');
    final path = p.join(dir.path, 'exa.db');

    // Stand up a v7-shaped schedule_items table (no lead_time_minutes) and
    // seed a row, the way an installed v7 build would have it on disk.
    final v7 = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 7,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE schedule_items (
              id TEXT PRIMARY KEY,
              title TEXT NOT NULL,
              description TEXT,
              location TEXT,
              start_at TEXT NOT NULL,
              end_at TEXT,
              source TEXT DEFAULT 'local',
              external_id TEXT,
              status TEXT DEFAULT 'Confirmed',
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            )
          ''');
        },
      ),
    );
    final now = DateTime.now().toIso8601String();
    await v7.insert('schedule_items', {
      'id': 'e1',
      'title': 'Standup',
      'start_at': now,
      'created_at': now,
      'updated_at': now,
    });
    await v7.close();

    // Opening through AppDatabase (version 8) runs the _applyV8 upgrade.
    final db = AppDatabase();
    await db.open(overridePath: path);
    final item = await ScheduleRepository(db).getById('e1');
    expect(item, isNotNull);
    expect(item!.title, 'Standup');
    expect(item.leadTimeMinutes, 0); // new column defaults to 0
    await db.close();

    await dir.delete(recursive: true);
  });

  test('v8 -> v9 upgrade adds auth_type and existing accounts stay '
      'password-based', () async {
    final dir = await Directory.systemTemp.createTemp('exa_migration');
    final path = p.join(dir.path, 'exa.db');

    // Stand up a v8-shaped mail_accounts table (no auth_type) and seed a
    // row, the way an installed v8 build would have it on disk.
    final v8 = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 8,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE mail_accounts (
              id TEXT PRIMARY KEY,
              display_name TEXT NOT NULL,
              email_address TEXT NOT NULL,
              username TEXT NOT NULL,
              imap_host TEXT NOT NULL,
              imap_port INTEGER NOT NULL DEFAULT 993,
              smtp_host TEXT,
              smtp_port INTEGER DEFAULT 465,
              use_ssl INTEGER NOT NULL DEFAULT 1,
              folder TEXT NOT NULL DEFAULT 'INBOX',
              sync_enabled INTEGER NOT NULL DEFAULT 1,
              last_sync_at TEXT,
              last_error TEXT,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            )
          ''');
        },
      ),
    );
    final now = DateTime.now().toIso8601String();
    await v8.insert('mail_accounts', {
      'id': 'a1',
      'display_name': 'Work mail',
      'email_address': 'user@example.com',
      'username': 'user@example.com',
      'imap_host': 'imap.example.com',
      'created_at': now,
      'updated_at': now,
    });
    await v8.close();

    // Opening through AppDatabase (version 9) runs the _applyV9 upgrade.
    final db = AppDatabase();
    await db.open(overridePath: path);
    final account =
        await MailAccountRepository(db).getById('a1');
    expect(account, isNotNull);
    expect(account!.authType, MailAccount.authPassword);
    expect(account.isGmail, isFalse);
    await db.close();

    await dir.delete(recursive: true);
  });

  test('v10 -> v16 upgrade adds every intelligence-layer table and keeps '
      'existing data', () async {
    final dir = await Directory.systemTemp.createTemp('exa_migration');
    final path = p.join(dir.path, 'exa.db');

    // Stand up a v10-shaped database with just enough schema plus a seed
    // row, the way an installed v10 build would have it on disk.
    final v10 = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 10,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE tasks (
              id TEXT PRIMARY KEY,
              title TEXT NOT NULL,
              description TEXT,
              status TEXT NOT NULL DEFAULT 'Pending',
              priority TEXT DEFAULT 'Normal',
              category TEXT,
              due_at TEXT,
              completed_at TEXT,
              source TEXT DEFAULT 'user',
              created_by TEXT DEFAULT 'user',
              device_event_id TEXT,
              recurrence_rule TEXT,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            )
          ''');
        },
      ),
    );
    final now = DateTime.now().toIso8601String();
    await v10.insert('tasks', {
      'id': 't1',
      'title': 'Existing task',
      'created_at': now,
      'updated_at': now,
    });
    await v10.close();

    // Opening through AppDatabase (version 16) runs migrations 11-16.
    final db = AppDatabase();
    await db.open(overridePath: path);

    const newTables = [
      'agent_entities',
      'entity_relationships',
      'active_entity_context',
      'agent_memories',
      'memory_entities',
      'workflow_skills',
      'workflow_skill_steps',
      'skill_executions',
      'skill_execution_steps',
      'completion_contracts',
      'completion_contract_actions',
      'idempotency_records',
      'replay_traces',
      'evaluation_scenarios',
      'evaluation_results',
    ];
    for (final table in newTables) {
      final exists = await db.db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
          [table]);
      expect(exists, isNotEmpty, reason: '$table must exist after upgrade');
    }

    // Pre-existing data survives.
    final tasks = await db.db.query('tasks');
    expect(tasks, hasLength(1));
    expect(tasks.single['title'], 'Existing task');

    await db.close();
    await dir.delete(recursive: true);
  });

  test('v16 -> v17 adds behavior params and keeps existing rules', () async {
    final dir = await Directory.systemTemp.createTemp('exa_migration');
    final path = p.join(dir.path, 'exa.db');

    // A v16-shaped behaviors table: the same columns, without params.
    final v16 = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 16,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE agent_behaviors (
              id TEXT PRIMARY KEY,
              behavior_key TEXT UNIQUE NOT NULL,
              title TEXT NOT NULL,
              description TEXT,
              behavior_type TEXT NOT NULL,
              rule_text TEXT NOT NULL,
              priority INTEGER DEFAULT 100,
              status TEXT NOT NULL DEFAULT 'Draft',
              risk_level TEXT NOT NULL DEFAULT 'Low Risk',
              requires_confirmation INTEGER DEFAULT 0,
              created_by TEXT DEFAULT 'agent',
              approved_by_user INTEGER DEFAULT 0,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE agent_behavior_versions (
              id TEXT PRIMARY KEY,
              behavior_id TEXT NOT NULL,
              version_number INTEGER NOT NULL,
              rule_text TEXT NOT NULL,
              change_reason TEXT,
              changed_by TEXT DEFAULT 'agent',
              created_at TEXT NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE behavior_change_requests (
              id TEXT PRIMARY KEY,
              behavior_id TEXT,
              proposed_title TEXT NOT NULL,
              proposed_rule_text TEXT NOT NULL,
              behavior_type TEXT NOT NULL DEFAULT 'preference_rule',
              reason TEXT,
              risk_level TEXT NOT NULL,
              status TEXT NOT NULL DEFAULT 'Pending',
              user_decision TEXT,
              created_at TEXT NOT NULL,
              decided_at TEXT
            )
          ''');
        },
      ),
    );
    final now = DateTime.now().toIso8601String();
    await v16.insert('agent_behaviors', {
      'id': 'b1',
      'behavior_key': 'be_brief',
      'title': 'Be brief',
      'behavior_type': 'preference_rule',
      'rule_text': 'Keep answers short.',
      'status': 'Active',
      'created_at': now,
      'updated_at': now,
    });
    await v16.close();

    final db = AppDatabase();
    await db.open(overridePath: path);

    for (final table in ['agent_behaviors', 'behavior_change_requests']) {
      final columns = await db.db.rawQuery('PRAGMA table_info($table)');
      expect(columns.any((c) => c['name'] == 'params'), isTrue,
          reason: '$table must have params after the upgrade');
    }

    // The existing rule survives and reads back with empty params.
    final behaviors = await BehaviorRepository(db).listActive();
    expect(behaviors, hasLength(1));
    expect(behaviors.single.ruleText, 'Keep answers short.');
    expect(behaviors.single.params, isEmpty);

    // And a new rule can store and read them.
    final saved = await BehaviorRepository(db).createActive(
      title: 'Quiet at night',
      behaviorType: 'notification_rule',
      ruleText: 'No alerts after 22:00.',
      params: {
        'quiet_hours': {'from': '22:00', 'to': '07:00'},
      },
    );
    final reloaded = await BehaviorRepository(db).getById(saved.id);
    expect((reloaded!.params['quiet_hours'] as Map)['to'], '07:00');

    await db.close();
    await dir.delete(recursive: true);
  });

  test('v17 -> v18 adds the job ledger and behavior governance columns',
      () async {
    final dir = await Directory.systemTemp.createTemp('exa_migration');
    final path = p.join(dir.path, 'exa.db');

    final v17 = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 17,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE scheduled_jobs (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              description TEXT,
              job_type TEXT NOT NULL,
              schedule_rule TEXT NOT NULL,
              status TEXT DEFAULT 'Active',
              last_run_at TEXT,
              next_run_at TEXT,
              created_by TEXT DEFAULT 'agent',
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE job_runs (
              id TEXT PRIMARY KEY,
              job_id TEXT NOT NULL,
              started_at TEXT NOT NULL,
              finished_at TEXT,
              status TEXT NOT NULL DEFAULT 'Running',
              result_summary TEXT,
              error_message TEXT
            )
          ''');
          await db.execute('''
            CREATE TABLE agent_behaviors (
              id TEXT PRIMARY KEY,
              behavior_key TEXT UNIQUE NOT NULL,
              title TEXT NOT NULL,
              description TEXT,
              behavior_type TEXT NOT NULL,
              rule_text TEXT NOT NULL,
              priority INTEGER DEFAULT 100,
              status TEXT NOT NULL DEFAULT 'Draft',
              risk_level TEXT NOT NULL DEFAULT 'Low Risk',
              requires_confirmation INTEGER DEFAULT 0,
              created_by TEXT DEFAULT 'agent',
              approved_by_user INTEGER DEFAULT 0,
              params TEXT,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            )
          ''');
        },
      ),
    );
    final now = DateTime.now().toIso8601String();
    await v17.insert('scheduled_jobs', {
      'id': 'j1',
      'name': 'Morning review',
      'job_type': 'daily_review',
      'schedule_rule': '{"type":"daily","time":"07:30"}',
      'created_at': now,
      'updated_at': now,
    });
    await v17.insert('job_runs', {
      'id': 'r1',
      'job_id': 'j1',
      'started_at': now,
      'status': 'Success',
    });
    await v17.insert('agent_behaviors', {
      'id': 'b1',
      'behavior_key': 'user_rule',
      'title': 'A rule the user approved',
      'behavior_type': 'preference_rule',
      'rule_text': 'Keep answers short.',
      'status': 'Active',
      'approved_by_user': 1,
      'created_at': now,
      'updated_at': now,
    });
    await v17.close();

    final db = AppDatabase();
    await db.open(overridePath: path);

    // Existing history survives, and old runs get the ledger defaults.
    final runs = await db.db.query('job_runs');
    expect(runs, hasLength(1));
    expect(runs.single['attempt'], 1);
    expect(runs.single['scheduled_for'], isNull);

    final jobs = await JobRepository(db).listAll();
    expect(jobs.single.behaviorMode, 'live');
    expect(jobs.single.missedRunPolicy, 'run_once_now');
    expect(jobs.single.maxAttempts, 3);

    // A rule the user had approved is treated as explicit, not as a
    // low-confidence guess that expiry or a conflict could sweep away.
    final behavior = (await BehaviorRepository(db).listActive()).single;
    expect(behavior.source, 'explicit');
    expect(behavior.confidence, 1.0);
    expect(behavior.lastConfirmedAt, isNotNull);

    // The occurrence lock exists and actually rejects a duplicate.
    await db.db.insert('job_runs', {
      'id': 'r2',
      'job_id': 'j1',
      'started_at': now,
      'status': 'Running',
      'scheduled_for': now,
    });
    await expectLater(
      db.db.insert('job_runs', {
        'id': 'r3',
        'job_id': 'j1',
        'started_at': now,
        'status': 'Running',
        'scheduled_for': now,
      }),
      throwsA(anything),
    );

    // Diagnostics storage is present.
    await DiagnosticsRepository(db)
        .record(code: 'TEST', message: 'hello');
    expect(await DiagnosticsRepository(db).recent(), hasLength(1));

    await db.close();
    await dir.delete(recursive: true);
  });

  test('v18 -> v19 adds memory lifecycle, provenance and the new ledgers',
      () async {
    final dir = await Directory.systemTemp.createTemp('exa_migration');
    final path = p.join(dir.path, 'exa.db');

    // A hand-built v18 schema carrying rows that must survive intact.
    final v18 = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 18,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE tasks (
              id TEXT PRIMARY KEY,
              title TEXT NOT NULL,
              status TEXT NOT NULL DEFAULT 'Pending',
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE agent_memories (
              id TEXT PRIMARY KEY,
              memory_type TEXT NOT NULL,
              content TEXT NOT NULL,
              summary TEXT,
              importance REAL NOT NULL DEFAULT 0.5,
              confidence REAL NOT NULL DEFAULT 0.5,
              source_type TEXT NOT NULL,
              source_id TEXT NOT NULL,
              expires_at TEXT,
              last_accessed_at TEXT,
              access_count INTEGER NOT NULL DEFAULT 0,
              user_confirmed INTEGER NOT NULL DEFAULT 0,
              is_sensitive INTEGER NOT NULL DEFAULT 0,
              is_archived INTEGER NOT NULL DEFAULT 0,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE memory_entities (
              memory_id TEXT NOT NULL,
              entity_id TEXT NOT NULL,
              PRIMARY KEY(memory_id, entity_id)
            )
          ''');
        },
      ),
    );
    final then = DateTime(2026, 1, 5).toIso8601String();
    await v18.insert('tasks', {
      'id': 't1',
      'title': 'A task the user made',
      'created_at': then,
      'updated_at': then,
    });
    await v18.insert('agent_memories', {
      'id': 'm1',
      'memory_type': 'semantic',
      'content': 'The user confirmed they prefer short digests',
      'source_type': 'conversation',
      'source_id': 'turn_1',
      'user_confirmed': 1,
      'created_at': then,
      'updated_at': then,
    });
    await v18.insert('agent_memories', {
      'id': 'm2',
      'memory_type': 'episodic',
      'content': 'Digested 4 emails',
      'source_type': 'agent_turn',
      'source_id': 'turn_1',
      'created_at': then,
      'updated_at': then,
    });
    await v18.close();

    final db = AppDatabase();
    await db.open(overridePath: path);

    // Existing rows survive and get sensible lifecycle defaults.
    final memories = MemoryRepository(db);
    final confirmed = await memories.getById('m1');
    expect(confirmed, isNotNull);
    expect(confirmed!.content, contains('short digests'));
    // A memory the user confirmed is provenance-tagged as theirs, not left
    // looking like a guess.
    expect(confirmed.provenance, MemoryProvenance.userStatement);
    expect(confirmed.lastConfirmedAt, isNotNull);
    // observed_at is backfilled from created_at rather than left null.
    expect(confirmed.observedAt, DateTime.parse(then));

    final derived = await memories.getById('m2');
    expect(derived!.provenance, MemoryProvenance.deterministicInference);
    expect(derived.kind, MemoryKind.episodicEvent);
    expect(derived.isContradicted, isFalse);

    // Creation provenance columns exist on an old task, defaulting to null
    // (which reads as "made by the user", the truth for a pre-v19 row).
    final tasks = await db.db.query('tasks');
    expect(tasks.single['origin_type'], isNull);
    expect(tasks.single.containsKey('origin_run_id'), isTrue);
    expect(tasks.single['title'], 'A task the user made');

    // The new ledgers exist and their locks work.
    await db.db.insert('behavior_trigger_firings', {
      'id': 'f1',
      'behavior_id': 'b1',
      'event_id': 'sync_1',
      'fired_on': '2026-07-27',
      'created_at': then,
    });
    await expectLater(
      db.db.insert('behavior_trigger_firings', {
        'id': 'f2',
        'behavior_id': 'b1',
        'event_id': 'sync_1',
        'fired_on': '2026-07-27',
        'created_at': then,
      }),
      throwsA(anything),
    );

    for (final table in const [
      'conversation_capsules',
      'token_calibration_samples',
      'service_circuits',
    ]) {
      expect(await db.db.query(table), isEmpty, reason: '$table should exist');
    }

    await db.close();
    await dir.delete(recursive: true);
  });

  test('v19 -> v20 adds the planning board and keeps the tasks it plans',
      () async {
    final dir = await Directory.systemTemp.createTemp('exa_migration');
    final path = p.join(dir.path, 'exa.db');

    // A v19 database with a task already on it: upgrading must add the board
    // without disturbing the work it will plan.
    final v19 = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 19,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE tasks (
              id TEXT PRIMARY KEY,
              title TEXT NOT NULL,
              status TEXT NOT NULL DEFAULT 'Pending',
              due_at TEXT,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            )
          ''');
        },
      ),
    );
    final then = DateTime(2026, 8, 1).toIso8601String();
    await v19.insert('tasks', {
      'id': 't1',
      'title': 'Survives the upgrade',
      'status': 'Pending',
      'due_at': DateTime(2026, 8, 28, 17).toIso8601String(),
      'created_at': then,
      'updated_at': then,
    });
    await v19.close();

    final db = AppDatabase();
    await db.open(overridePath: path);

    expect((await db.db.query('tasks')).single['title'],
        'Survives the upgrade');

    final plans = DayPlanRepository(db);
    final task = (await TaskRepository(db).list()).single;
    await plans.plan(
      day: DateTime(2026, 8, 10),
      title: task.title,
      startMinute: 9 * 60,
      sourceType: DayPlanEntry.sourceTask,
      sourceId: task.id,
    );
    expect(await plans.listForDay(DateTime(2026, 8, 10)), hasLength(1));
    // The deadline is untouched by planning - on a migrated database too.
    expect((await TaskRepository(db).getById(task.id))!.dueAt,
        DateTime(2026, 8, 28, 17));

    // The partial unique index has to survive the migration, or the same
    // task could be planned twice on one day.
    await expectLater(
      db.db.insert('day_plan_entries', {
        'id': 'dup',
        'plan_date': '2026-08-10',
        'source_type': DayPlanEntry.sourceTask,
        'source_id': task.id,
        'title': 'Duplicate',
        'start_minute': 600,
        'duration_minutes': 30,
        'status': 'planned',
        'created_by': 'user',
        'created_at': then,
        'updated_at': then,
      }),
      throwsA(anything),
    );

    await db.close();
    await dir.delete(recursive: true);
  });

  test('v20 -> v21 adds chat messages and dedupes them by content hash',
      () async {
    final dir = await Directory.systemTemp.createTemp('exa_migration');
    final path = p.join(dir.path, 'exa.db');

    // A v20 database with mail already on it: chat capture is a new table
    // beside email_items, never a change to it.
    final v20 = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 20,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE email_items (
              id TEXT PRIMARY KEY,
              subject TEXT NOT NULL,
              body TEXT NOT NULL,
              digested INTEGER DEFAULT 0,
              created_at TEXT NOT NULL
            )
          ''');
        },
      ),
    );
    await v20.insert('email_items', {
      'id': 'm1',
      'subject': 'Still here',
      'body': 'Mail is untouched by the chat migration',
      'created_at': DateTime(2026, 8, 1).toIso8601String(),
    });
    await v20.close();

    final db = AppDatabase();
    await db.open(overridePath: path);
    expect((await db.db.query('email_items')).single['subject'], 'Still here');

    final messages = InboundMessageRepository(db);
    final sentAt = DateTime(2026, 8, 12, 9, 14);
    InboundMessage build() => InboundMessage(
          id: 'ignored-by-fingerprint',
          channel: MessageChannels.whatsapp,
          conversationId: 'alice',
          conversationTitle: 'Alice',
          sender: 'Alice',
          body: 'Can we move to Thursday?',
          sentAt: sentAt,
          externalId: InboundMessage.fingerprint(
            channel: MessageChannels.whatsapp,
            conversationId: 'alice',
            sender: 'Alice',
            sentAt: sentAt,
            body: 'Can we move to Thursday?',
          ),
          createdAt: DateTime(2026, 8, 12, 9, 14, 30),
        );

    expect(await messages.add(build()), isNotNull);
    // WhatsApp re-posts a chat's recent messages on every new arrival, so the
    // same message really does come back many times. The partial unique index
    // is what stops that becoming a duplicate storm - and it has to survive
    // the migration, not just exist on a fresh install.
    expect(await messages.add(build()), isNull,
        reason: 'the same message must not be stored twice');
    expect(await messages.countUndigested(), 1);

    await db.close();
    await dir.delete(recursive: true);
  });

  test('v21 -> v22 adds per-job muting and leaves existing jobs notifying',
      () async {
    final dir = await Directory.systemTemp.createTemp('exa_migration');
    final path = p.join(dir.path, 'exa.db');

    final v21 = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 21,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE scheduled_jobs (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              description TEXT,
              job_type TEXT NOT NULL,
              schedule_rule TEXT NOT NULL,
              status TEXT DEFAULT 'Active',
              last_run_at TEXT,
              next_run_at TEXT,
              created_by TEXT DEFAULT 'agent',
              permissions_json TEXT,
              behavior_mode TEXT NOT NULL DEFAULT 'live',
              behavior_snapshot TEXT,
              behavior_version INTEGER,
              missed_run_policy TEXT NOT NULL DEFAULT 'run_once_now',
              timeout_seconds INTEGER NOT NULL DEFAULT 300,
              max_attempts INTEGER NOT NULL DEFAULT 3,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            )
          ''');
        },
      ),
    );
    final then = DateTime(2026, 8, 14).toIso8601String();
    await v21.insert('scheduled_jobs', {
      'id': 'j1',
      'name': 'Morning review',
      'job_type': 'daily_review',
      'schedule_rule': '{"type":"daily","time":"07:30"}',
      'created_at': then,
      'updated_at': then,
    });
    await v21.close();

    final db = AppDatabase();
    await db.open(overridePath: path);

    final jobs = JobRepository(db);
    // Silence is opt-in: a job that predates the switch keeps notifying.
    expect((await jobs.getById('j1'))!.muteNotifications, isFalse);

    final muted = await jobs.update('j1', muteNotifications: true);
    expect(muted!.muteNotifications, isTrue);
    // And muting must not disturb the schedule it was set on.
    expect(muted.scheduleRule['time'], '07:30');

    await db.close();
    await dir.delete(recursive: true);
  });

  test('v22 -> v23 adds collections, and existing data survives beside them',
      () async {
    final dir = await Directory.systemTemp.createTemp('exa_migration');
    final path = p.join(dir.path, 'exa.db');

    // A v22 file with a task on it - what an installed build has on disk.
    final v22 = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 22,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE tasks (
              id TEXT PRIMARY KEY,
              title TEXT NOT NULL,
              status TEXT DEFAULT 'Pending',
              priority TEXT DEFAULT 'Normal',
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            )
          ''');
        },
      ),
    );
    final then = DateTime(2026, 8, 19).toIso8601String();
    await v22.insert('tasks', {
      'id': 't1',
      'title': 'Existing task',
      'created_at': then,
      'updated_at': then,
    });
    await v22.close();

    final db = AppDatabase();
    await db.open(overridePath: path);

    // The upgrade created the collection store...
    final records = UserCollectionRepository(db);
    await records.define(
      name: 'notes',
      title: 'Notes',
      fields: const [CollectionField(name: 'title', required: true)],
    );
    await records.addRecord(
        collection: 'notes', values: {'title': 'First note'});
    expect((await records.listRecords('notes')).single['title'],
        'First note');

    // ...and touched nothing that was already there.
    final tasks = TaskRepository(db);
    expect((await tasks.getById('t1'))!.title, 'Existing task');

    await db.close();
    await dir.delete(recursive: true);
  });

  test('v25 -> v26 adds transcript state to media and keeps every row',
      () async {
    final dir = await Directory.systemTemp.createTemp('exa_migration');
    final path = p.join(dir.path, 'exa.db');

    // The schema an installed v25 build leaves on disk: inbound_media with
    // the reserved transcript_text but no transcript state at all, holding
    // one voice note and one photo on a real message. The upgrade must add
    // the state without moving a byte of what is already there.
    final v25 = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 25,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE inbound_messages (
              id TEXT PRIMARY KEY,
              body TEXT NOT NULL,
              created_at TEXT NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE inbound_media (
              id TEXT PRIMARY KEY,
              message_id TEXT NOT NULL
                  REFERENCES inbound_messages(id) ON DELETE CASCADE,
              kind TEXT NOT NULL,
              mime_type TEXT,
              file_path TEXT NOT NULL,
              file_name TEXT,
              size_bytes INTEGER,
              content_hash TEXT NOT NULL,
              transcript_text TEXT,
              created_at TEXT NOT NULL
            )
          ''');
        },
      ),
    );
    final then = DateTime(2026, 10, 30).toIso8601String();
    await v25.insert('inbound_messages', {
      'id': 'msg1',
      'body': '',
      'created_at': then,
    });
    await v25.insert('inbound_media', {
      'id': 'media-audio',
      'message_id': 'msg1',
      'kind': 'audio',
      'mime_type': 'audio/ogg; codecs=opus',
      'file_path': '/data/media/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.ogg',
      'file_name': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.ogg',
      'size_bytes': 24576,
      'content_hash': 'a' * 32,
      'created_at': then,
    });
    await v25.insert('inbound_media', {
      'id': 'media-photo',
      'message_id': 'msg1',
      'kind': 'image',
      'mime_type': 'image/jpeg',
      'file_path': '/data/media/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.jpg',
      'file_name': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.jpg',
      'size_bytes': 1024,
      'content_hash': 'b' * 32,
      'created_at': then,
    });
    await v25.close();

    final db = AppDatabase();
    await db.open(overridePath: path);

    final version = await db.db.rawQuery('PRAGMA user_version');
    expect(version.first.values.first, 26);

    // Every pre-existing row survives, and the new columns carry the
    // never-offered defaults on them - which is the literal truth for media
    // captured before the pass existed.
    final rows = await db.db.query('inbound_media', orderBy: 'id');
    expect(rows, hasLength(2));
    final audio = rows.firstWhere((r) => r['id'] == 'media-audio');
    expect(audio['content_hash'], 'a' * 32);
    expect(audio['transcript_status'], 'none');
    expect(audio['transcript_attempts'], 0);
    expect(audio['transcribed_at'], isNull);
    expect(audio['transcript_text'], isNull);

    // The model reads a migrated row the same way, so no caller needs to
    // know which build wrote it.
    final mediaRepo = InboundMediaRepository(db);
    final migrated = await mediaRepo.get('media-audio');
    expect(migrated!.transcriptStatus, InboundMedia.statusNone);
    expect(migrated.transcriptAttempts, 0);
    expect(migrated.transcribedAt, isNull);
    expect(migrated.isTranscribed, isFalse);

    // The pass's index exists on an upgraded database too - pendingTrans-
    // criptions runs against this very file on the next background job.
    final indexes = await db.db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='index' "
      "AND name='idx_inbound_media_transcript'",
    );
    expect(indexes, isNotEmpty);

    // And the pass sees the migrated voice note immediately: no re-capture,
    // no row silently reading as already-done.
    expect(
      (await mediaRepo.pendingTranscriptions()).map((m) => m.id),
      ['media-audio'],
    );

    // Recording an answer on a migrated row behaves exactly as on one
    // written by the new build.
    await mediaRepo.recordTranscription(
      'media-audio',
      text: 'Move the standup to Thursday.',
      status: InboundMedia.statusDone,
    );
    final done = await mediaRepo.get('media-audio');
    expect(done!.transcriptStatus, InboundMedia.statusDone);
    expect(done.transcriptText, 'Move the standup to Thursday.');
    expect(done.transcribedAt, isNotNull);
    expect(done.transcriptAttempts, 1);
    expect(done.isTranscribed, isTrue);
    expect(await mediaRepo.pendingTranscriptions(), isEmpty);

    await db.close();
    await dir.delete(recursive: true);
  });
}
