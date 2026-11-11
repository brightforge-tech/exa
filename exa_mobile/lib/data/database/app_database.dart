import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'write_coordinator.dart';

/// Local-first SQLite storage. This is the single source of truth for the
/// app; every agent action that changes state goes through a table here.
class AppDatabase {
  static const _dbName = 'exa.db';
  static const _dbVersion = 26;

  /// How long a write waits for another isolate's lock before giving up.
  /// The app, the overlay, the WorkManager isolate and the alarm isolates
  /// all open this same file, so contention is normal rather than
  /// exceptional; without a busy timeout the loser of a race gets an
  /// immediate SQLITE_BUSY instead of waiting the few milliseconds the
  /// other writer actually needs.
  static const busyTimeout = Duration(seconds: 5);

  Database? _db;

  /// Serializes this isolate's writes and retries only lock contention.
  /// One per open database, so every caller sharing this handle shares the
  /// same write slot.
  final writes = WriteCoordinator();

  /// Result of the integrity check run at open. Null until [open] finishes.
  DatabaseHealth? health;

  Database get db {
    final database = _db;
    if (database == null) {
      throw StateError('AppDatabase.open() must be called before use');
    }
    return database;
  }

  /// Runs [action] in one transaction, serialized against this isolate's
  /// other writes.
  ///
  /// This is where a record and the log entry proving it exists belong
  /// together: committed separately, a process death between them leaves
  /// Exa having created something it has no record of creating, and the
  /// next run has no way to know not to do it again.
  Future<T> criticalWrite<T>(Future<T> Function(Transaction txn) action) =>
      writes.transaction(db, action);

  Future<void> open({String? overridePath}) async {
    // Reopen if a stale handle is left over (e.g. closed elsewhere in the
    // process) rather than handing out a dead connection.
    if (_db != null && _db!.isOpen) return;
    _db = null;
    final path =
        overridePath ?? p.join(await getDatabasesPath(), _dbName);
    _db = await openDatabase(
      path,
      version: _dbVersion,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
        // WAL lets the UI keep reading while a background isolate writes,
        // which is the normal state of this app: readers no longer block on
        // the job runner's transaction and vice versa.
        //
        // Not every platform honours it (in-memory databases in tests do
        // not), and failing to enable it is a performance regression, never
        // a correctness one - so a rejection must not stop the app opening.
        try {
          await db.rawQuery('PRAGMA journal_mode = WAL');
        } catch (_) {
          // Platform declined WAL; the default journal still works.
        }
        // `rawQuery`, not `execute`: this PRAGMA *returns the value it set*,
        // and Android's SQLiteDatabase rejects a row-returning statement sent
        // through execSQL ("Queries can be performed using ... query or
        // rawQuery methods only"). The FFI backend the tests run on is
        // happy either way, so this only ever fails on a real device.
        try {
          await db.rawQuery(
              'PRAGMA busy_timeout = ${busyTimeout.inMilliseconds}');
        } catch (_) {
          // No busy timeout: contention surfaces as SQLITE_BUSY, which the
          // write coordinator retries. Degraded, not broken.
        }
        // WAL's default (FULL) fsyncs on every commit. NORMAL is durable
        // across app crashes - only a power cut can lose the last commits -
        // and is what makes many small writes affordable on a phone.
        try {
          await db.execute('PRAGMA synchronous = NORMAL');
        } catch (_) {
          // Non-fatal.
        }
      },
      onCreate: _onCreate,
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await _createV2Tables(db);
        }
        if (oldVersion < 3) {
          await _createV3Tables(db);
        }
        if (oldVersion < 4) {
          await _applyV4(db);
        }
        if (oldVersion < 5) {
          await _applyV5(db);
        }
        if (oldVersion < 6) {
          await _applyV6(db);
        }
        if (oldVersion < 7) {
          await _applyV7(db);
        }
        if (oldVersion < 8) {
          await _applyV8(db);
        }
        if (oldVersion < 9) {
          await _applyV9(db);
        }
        if (oldVersion < 10) {
          await _applyV10(db);
        }
        if (oldVersion < 11) {
          await _applyV11(db);
        }
        if (oldVersion < 12) {
          await _applyV12(db);
        }
        if (oldVersion < 13) {
          await _applyV13(db);
        }
        if (oldVersion < 14) {
          await _applyV14(db);
        }
        if (oldVersion < 15) {
          await _applyV15(db);
        }
        if (oldVersion < 16) {
          await _applyV16(db);
        }
        if (oldVersion < 17) {
          await _applyV17(db);
        }
        if (oldVersion < 18) {
          await _applyV18(db);
        }
        if (oldVersion < 19) {
          await _applyV19(db);
        }
        if (oldVersion < 20) {
          await _applyV20(db);
        }
        if (oldVersion < 21) {
          await _applyV21(db);
        }
        if (oldVersion < 22) {
          await _applyV22(db);
        }
        if (oldVersion < 23) {
          await _applyV23(db);
        }
        if (oldVersion < 24) {
          await _applyV24(db);
        }
        if (oldVersion < 25) {
          await _applyV25(db);
        }
        if (oldVersion < 26) {
          await _applyV26(db);
        }
      },
    );
    // Four isolates open this file and any of them can be killed mid-write.
    // WAL makes that recoverable; this is the part that notices. Failure to
    // check is never a reason to refuse to start - the app is more useful
    // running with a warning than not running at all.
    try {
      health = await DatabaseHealth.check(_db!);
    } catch (_) {
      health = null;
    }
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  /// Wipes every user-facing table. Used by "Clear all data" in Settings.
  Future<void> clearAllData() async {
    const tables = [
      'tasks',
      'reminders',
      'schedule_items',
      'day_plan_entries',
      'dynamic_screens',
      'email_items',
      // v25 media rows before their messages: the cascade would remove them
      // anyway, but naming the table says so instead of relying on the FK.
      'inbound_media',
      'inbound_messages',
      'mail_accounts',
      'pending_calendar_events',
      'job_runs',
      'scheduled_jobs',
      'tool_calls',
      'browser_context_items',
      'browser_sessions',
      'connected_accounts',
      'agent_behaviors',
      'agent_behavior_versions',
      'behavior_change_requests',
      'behavior_evaluations',
      'diagnostic_events',
      'chat_messages',
      'audit_logs',
      'attachments',
      'transcripts',
      'settings',
      // v23: agent-defined collections and their records.
      'user_records',
      'user_collections',
      // Intelligence layer (entity graph, memory, skills, contracts,
      // idempotency, replay). Order respects foreign keys.
      'memory_entities',
      'agent_memories',
      'active_entity_context',
      'entity_relationships',
      'agent_entities',
      'skill_execution_steps',
      'skill_executions',
      'workflow_skill_steps',
      'workflow_skills',
      'completion_contract_actions',
      'completion_contracts',
      'idempotency_records',
      'replay_traces',
      'evaluation_results',
      'evaluation_scenarios',
      // v19: lifecycle, calibration and governance ledgers.
      'conversation_capsules',
      'token_calibration_samples',
      'service_circuits',
      'behavior_trigger_firings',
    ];
    final batch = db.batch();
    for (final table in tables) {
      batch.delete(table);
    }
    await batch.commit(noResult: true);
  }

  Future<void> _onCreate(Database db, int version) async {
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
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE reminders (
          id TEXT PRIMARY KEY,
          task_id TEXT,
          title TEXT NOT NULL,
          description TEXT,
          remind_at TEXT NOT NULL,
          recurrence_rule TEXT,
          status TEXT NOT NULL DEFAULT 'Active',
          notification_id INTEGER,
          created_by TEXT DEFAULT 'agent',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          FOREIGN KEY (task_id) REFERENCES tasks(id)
      )
    ''');

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
          lead_time_minutes INTEGER DEFAULT 0,
          device_event_id TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE dynamic_screens (
          id TEXT PRIMARY KEY,
          screen_key TEXT UNIQUE NOT NULL,
          title TEXT NOT NULL,
          description TEXT,
          schema_json TEXT NOT NULL,
          created_by TEXT DEFAULT 'agent',
          is_saved INTEGER DEFAULT 0,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
      )
    ''');

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
          mute_notifications INTEGER NOT NULL DEFAULT 0,
          timeout_seconds INTEGER NOT NULL DEFAULT 1800,
          max_attempts INTEGER NOT NULL DEFAULT 3,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE tool_calls (
          id TEXT PRIMARY KEY,
          tool_name TEXT NOT NULL,
          input_json TEXT,
          output_json TEXT,
          status TEXT NOT NULL,
          error_message TEXT,
          created_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE browser_context_items (
          id TEXT PRIMARY KEY,
          session_id TEXT,
          page_title TEXT,
          page_url TEXT,
          content_summary TEXT,
          extracted_text TEXT,
          source_app TEXT,
          created_at TEXT NOT NULL
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
          params_schema_version INTEGER NOT NULL DEFAULT 1,
          enforcement_mode TEXT NOT NULL DEFAULT 'advisory',
          source TEXT NOT NULL DEFAULT 'inferred',
          confidence REAL NOT NULL DEFAULT 0.5,
          scope_intent TEXT,
          conflict_group TEXT,
          version INTEGER NOT NULL DEFAULT 1,
          evidence_count INTEGER NOT NULL DEFAULT 1,
          negative_feedback_count INTEGER NOT NULL DEFAULT 0,
          last_used_at TEXT,
          last_confirmed_at TEXT,
          expires_at TEXT,
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
          created_at TEXT NOT NULL,
          FOREIGN KEY (behavior_id) REFERENCES agent_behaviors(id)
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
          params TEXT,
          created_at TEXT NOT NULL,
          decided_at TEXT,
          FOREIGN KEY (behavior_id) REFERENCES agent_behaviors(id)
      )
    ''');

    await db.execute('''
      CREATE TABLE behavior_evaluations (
          id TEXT PRIMARY KEY,
          behavior_id TEXT NOT NULL,
          evaluation_note TEXT NOT NULL,
          success_score INTEGER,
          failure_reason TEXT,
          created_at TEXT NOT NULL,
          FOREIGN KEY (behavior_id) REFERENCES agent_behaviors(id)
      )
    ''');

    await db.execute('''
      CREATE TABLE chat_messages (
          id TEXT PRIMARY KEY,
          role TEXT NOT NULL,
          content TEXT NOT NULL,
          meta_json TEXT,
          created_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE settings (
          key TEXT PRIMARY KEY,
          value TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE audit_logs (
          id TEXT PRIMARY KEY,
          actor TEXT NOT NULL,
          action TEXT NOT NULL,
          detail_json TEXT,
          created_at TEXT NOT NULL
      )
    ''');

    await _createV2Tables(db);
    await _createV3Tables(db);
    await _applyV4(db);
    await _applyV5(db);
    await _applyV6(db);
    await _applyV7(db);
    await _applyV8(db);
    await _applyV9(db);
    await _applyV11(db);
    await _applyV12(db);
    await _applyV13(db);
    await _applyV14(db);
    await _applyV15(db);
    await _applyV16(db);
    await _applyV17(db);
    await _applyV18(db);
    await _applyV19(db);
    await _applyV20(db);
    await _applyV21(db);
    await _applyV22(db);
    await _applyV23(db);
    await _applyV25(db);
    await _applyV26(db);

    await db.execute(
        'CREATE INDEX idx_tasks_status ON tasks(status)');
    await db.execute(
        'CREATE INDEX idx_tasks_due_at ON tasks(due_at)');
    await db.execute(
        'CREATE INDEX idx_reminders_remind_at ON reminders(remind_at)');
    await db.execute(
        'CREATE INDEX idx_schedule_start_at ON schedule_items(start_at)');
    await db.execute(
        'CREATE INDEX idx_tool_calls_created ON tool_calls(created_at)');
    await db.execute(
        'CREATE INDEX idx_chat_created ON chat_messages(created_at)');
  }

  /// Tables added in schema v2 (Phases 3-6: scheduler runs, browser
  /// sessions, connected accounts).
  static Future<void> _createV2Tables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS job_runs (
          id TEXT PRIMARY KEY,
          job_id TEXT NOT NULL,
          started_at TEXT NOT NULL,
          finished_at TEXT,
          status TEXT NOT NULL DEFAULT 'Running',
          result_summary TEXT,
          error_message TEXT,
          scheduled_for TEXT,
          attempt INTEGER NOT NULL DEFAULT 1,
          lease_until TEXT,
          trigger_source TEXT,
          behavior_version INTEGER,
          input_hash TEXT,
          model_id TEXT,
          tokens_in INTEGER,
          tokens_out INTEGER,
          error_code TEXT,
          FOREIGN KEY (job_id) REFERENCES scheduled_jobs(id)
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS browser_sessions (
          id TEXT PRIMARY KEY,
          title TEXT,
          url TEXT NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS connected_accounts (
          id TEXT PRIMARY KEY,
          provider TEXT NOT NULL,
          display_name TEXT NOT NULL,
          access_type TEXT NOT NULL DEFAULT 'browser_session',
          email_enabled INTEGER DEFAULT 0,
          calendar_enabled INTEGER DEFAULT 0,
          contacts_enabled INTEGER DEFAULT 0,
          files_enabled INTEGER DEFAULT 0,
          sync_frequency TEXT,
          last_sync_at TEXT,
          permission_status TEXT DEFAULT 'Connected',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
      )
    ''');

    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_job_runs_job ON job_runs(job_id)');
  }

  /// Tables added in schema v3: user-supplied emails for the agent to
  /// digest (pasted manually until API integrations land).
  static Future<void> _createV3Tables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS email_items (
          id TEXT PRIMARY KEY,
          subject TEXT NOT NULL,
          sender TEXT,
          received_at TEXT,
          body TEXT NOT NULL,
          summary TEXT,
          source TEXT DEFAULT 'manual',
          account_id TEXT,
          digested INTEGER DEFAULT 0,
          created_at TEXT NOT NULL
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_email_created '
        'ON email_items(created_at)');
  }

  /// Schema v4: IMAP/SMTP mail accounts, email dedupe ids, task recurrence.
  static Future<void> _applyV4(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS mail_accounts (
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
    // ALTER TABLE ADD COLUMN is idempotent-guarded by catching duplicates
    // (sqlite has no IF NOT EXISTS for columns).
    for (final statement in [
      'ALTER TABLE email_items ADD COLUMN external_id TEXT',
      'ALTER TABLE tasks ADD COLUMN recurrence_rule TEXT',
    ]) {
      try {
        await db.execute(statement);
      } catch (_) {
        // Column already exists.
      }
    }
  }

  /// Schema v6: files the user uploaded in chat and asked Exa to keep. The
  /// bytes live on disk (file_path); the row holds metadata plus the
  /// extracted text so Exa can recall a stored file without re-reading disk.
  static Future<void> _applyV6(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS attachments (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          mime_type TEXT,
          kind TEXT,
          size_bytes INTEGER,
          file_path TEXT NOT NULL,
          extracted_text TEXT,
          summary TEXT,
          source TEXT DEFAULT 'chat',
          created_at TEXT NOT NULL
      )
    ''');
  }

  /// Schema v8: per-event lead time, so an in-app event can alert the user a
  /// configurable number of minutes before it starts (0 = at start time).
  static Future<void> _applyV8(Database db) async {
    try {
      await db.execute(
          'ALTER TABLE schedule_items ADD COLUMN lead_time_minutes '
          'INTEGER DEFAULT 0');
    } catch (_) {
      // Column already exists (fresh database created it inline).
    }
  }

  /// Schema v9: how a mail account authenticates - 'password' (stored app
  /// password) or 'gmail' (Google sign-in; OAuth token fetched at use time,
  /// nothing stored).
  static Future<void> _applyV9(Database db) async {
    try {
      await db.execute("ALTER TABLE mail_accounts ADD COLUMN auth_type "
          "TEXT NOT NULL DEFAULT 'password'");
    } catch (_) {
      // Column already exists.
    }
  }

  /// Schema v7: standalone voice transcripts. Audio is never stored - only
  /// the transcribed text (plus an optional AI summary). Edited and revisited
  /// from the Transcribe feature, independent of the chat history.
  static Future<void> _applyV7(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS transcripts (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          content TEXT NOT NULL,
          summary TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
      )
    ''');
  }

  /// Schema v10: the phone-calendar mirror of an app-created event or task
  /// ("calendarId:eventId"), so edits and deletes propagate to the phone
  /// calendar and imports don't re-ingest our own mirrors as duplicates.
  static Future<void> _applyV10(Database db) async {
    for (final statement in [
      'ALTER TABLE schedule_items ADD COLUMN device_event_id TEXT',
      'ALTER TABLE tasks ADD COLUMN device_event_id TEXT',
    ]) {
      try {
        await db.execute(statement);
      } catch (_) {
        // Column already exists.
      }
    }
  }

  /// Schema v11 (intelligence layer, migration 1): the entity graph -
  /// persistent entities mirroring app records, typed relationships between
  /// them, and the per-conversation active entity context used to resolve
  /// pronouns and follow-ups.
  static Future<void> _applyV11(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS agent_entities (
          id TEXT PRIMARY KEY,
          entity_type TEXT NOT NULL,
          display_name TEXT NOT NULL,
          canonical_name TEXT,
          external_source TEXT,
          external_id TEXT,
          metadata_json TEXT NOT NULL DEFAULT '{}',
          confidence REAL NOT NULL DEFAULT 1.0,
          is_archived INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
      )
    ''');
    await db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_agent_entities_external '
        'ON agent_entities(external_source, external_id) '
        'WHERE external_source IS NOT NULL AND external_id IS NOT NULL');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_agent_entities_type '
        'ON agent_entities(entity_type)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_agent_entities_name '
        'ON agent_entities(canonical_name)');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS entity_relationships (
          id TEXT PRIMARY KEY,
          source_entity_id TEXT NOT NULL,
          target_entity_id TEXT NOT NULL,
          relationship_type TEXT NOT NULL,
          custom_type TEXT,
          metadata_json TEXT NOT NULL DEFAULT '{}',
          confidence REAL NOT NULL DEFAULT 1.0,
          source TEXT,
          valid_from TEXT,
          valid_until TEXT,
          created_at TEXT NOT NULL,
          FOREIGN KEY(source_entity_id) REFERENCES agent_entities(id),
          FOREIGN KEY(target_entity_id) REFERENCES agent_entities(id)
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_entity_relationships_source '
        'ON entity_relationships(source_entity_id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_entity_relationships_target '
        'ON entity_relationships(target_entity_id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_entity_relationships_type '
        'ON entity_relationships(relationship_type)');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS active_entity_context (
          conversation_id TEXT NOT NULL,
          entity_id TEXT NOT NULL,
          entity_type TEXT NOT NULL,
          display_name TEXT NOT NULL,
          external_id TEXT,
          salience REAL NOT NULL,
          position_index INTEGER,
          last_mentioned_at TEXT NOT NULL,
          PRIMARY KEY(conversation_id, entity_id),
          FOREIGN KEY(entity_id) REFERENCES agent_entities(id)
      )
    ''');
  }

  /// Schema v12 (migration 2): hierarchical agent memory plus its
  /// memory<->entity join table.
  static Future<void> _applyV12(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS agent_memories (
          id TEXT PRIMARY KEY,
          memory_type TEXT NOT NULL,
          content TEXT NOT NULL,
          summary TEXT,
          importance REAL NOT NULL DEFAULT 0.5,
          confidence REAL NOT NULL DEFAULT 0.5,
          source_type TEXT NOT NULL,
          source_id TEXT NOT NULL,
          embedding_blob BLOB,
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
    await db.execute('CREATE INDEX IF NOT EXISTS idx_agent_memories_type '
        'ON agent_memories(memory_type)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_agent_memories_source '
        'ON agent_memories(source_type, source_id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_agent_memories_expiration '
        'ON agent_memories(expires_at)');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS memory_entities (
          memory_id TEXT NOT NULL,
          entity_id TEXT NOT NULL,
          PRIMARY KEY(memory_id, entity_id),
          FOREIGN KEY(memory_id) REFERENCES agent_memories(id),
          FOREIGN KEY(entity_id) REFERENCES agent_entities(id)
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_memory_entities_entity '
        'ON memory_entities(entity_id)');
  }

  /// Schema v13 (migration 3): versioned workflow skills, their steps, and
  /// per-run execution logs.
  static Future<void> _applyV13(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS workflow_skills (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          description TEXT NOT NULL,
          version INTEGER NOT NULL,
          required_domains_json TEXT NOT NULL,
          required_outputs_json TEXT NOT NULL,
          trigger_examples_json TEXT NOT NULL DEFAULT '[]',
          input_schema_json TEXT NOT NULL DEFAULT '{}',
          execution_mode TEXT NOT NULL DEFAULT 'guided',
          is_enabled INTEGER NOT NULL DEFAULT 1,
          is_system_skill INTEGER NOT NULL DEFAULT 1,
          requires_confirmation INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
      )
    ''');
    await db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_workflow_skills_name_version '
        'ON workflow_skills(name, version)');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS workflow_skill_steps (
          id TEXT PRIMARY KEY,
          skill_id TEXT NOT NULL,
          step_key TEXT NOT NULL,
          step_order INTEGER NOT NULL,
          name TEXT NOT NULL,
          tool_name TEXT NOT NULL,
          argument_template_json TEXT NOT NULL DEFAULT '{}',
          depends_on_json TEXT NOT NULL DEFAULT '[]',
          condition_expression TEXT,
          failure_policy TEXT NOT NULL,
          max_retries INTEGER NOT NULL DEFAULT 0,
          requires_confirmation INTEGER NOT NULL DEFAULT 0,
          is_optional INTEGER NOT NULL DEFAULT 0,
          for_each_path TEXT,
          FOREIGN KEY(skill_id) REFERENCES workflow_skills(id)
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS skill_executions (
          id TEXT PRIMARY KEY,
          skill_id TEXT NOT NULL,
          skill_version INTEGER NOT NULL,
          agent_turn_id TEXT NOT NULL,
          input_json TEXT NOT NULL,
          status TEXT NOT NULL,
          started_at TEXT NOT NULL,
          completed_at TEXT,
          failure_reason TEXT,
          FOREIGN KEY(skill_id) REFERENCES workflow_skills(id)
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS skill_execution_steps (
          id TEXT PRIMARY KEY,
          skill_execution_id TEXT NOT NULL,
          skill_step_id TEXT NOT NULL,
          status TEXT NOT NULL,
          arguments_json TEXT,
          result_json TEXT,
          error_message TEXT,
          retry_count INTEGER NOT NULL DEFAULT 0,
          started_at TEXT,
          completed_at TEXT,
          FOREIGN KEY(skill_execution_id) REFERENCES skill_executions(id)
      )
    ''');
  }

  /// Schema v14 (migration 4): persisted completion contracts and their
  /// per-action statuses.
  static Future<void> _applyV14(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS completion_contracts (
          id TEXT PRIMARY KEY,
          agent_turn_id TEXT NOT NULL,
          original_request TEXT NOT NULL,
          domains_json TEXT,
          required_outputs_json TEXT NOT NULL,
          constraints_json TEXT NOT NULL DEFAULT '[]',
          assumptions_json TEXT NOT NULL DEFAULT '[]',
          skill_id TEXT,
          skill_version INTEGER,
          requires_confirmation INTEGER NOT NULL DEFAULT 0,
          requires_synthesis INTEGER NOT NULL,
          requires_verification INTEGER NOT NULL,
          created_at TEXT NOT NULL
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_completion_contracts_turn '
        'ON completion_contracts(agent_turn_id)');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS completion_contract_actions (
          id TEXT PRIMARY KEY,
          contract_id TEXT NOT NULL,
          description TEXT NOT NULL,
          status TEXT NOT NULL,
          required INTEGER NOT NULL,
          expected_tool_names_json TEXT NOT NULL DEFAULT '[]',
          entity_ids_json TEXT NOT NULL DEFAULT '[]',
          failure_reason TEXT,
          FOREIGN KEY(contract_id) REFERENCES completion_contracts(id)
      )
    ''');
  }

  /// Schema v15 (migration 5): idempotency records guarding side-effecting
  /// tool calls against duplicate execution.
  static Future<void> _applyV15(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS idempotency_records (
          key TEXT PRIMARY KEY,
          agent_turn_id TEXT NOT NULL DEFAULT '',
          tool_name TEXT NOT NULL,
          result_json TEXT,
          created_at TEXT NOT NULL
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_idempotency_records_created '
        'ON idempotency_records(created_at)');
  }

  /// Schema v16 (migration 6): replay traces plus evaluation scenarios and
  /// results.
  static Future<void> _applyV16(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS replay_traces (
          id TEXT PRIMARY KEY,
          agent_turn_id TEXT NOT NULL,
          user_request TEXT NOT NULL,
          routing_result_json TEXT NOT NULL,
          contract_json TEXT NOT NULL,
          memories_json TEXT NOT NULL,
          active_entities_json TEXT NOT NULL,
          tool_executions_json TEXT NOT NULL,
          execution_report_json TEXT NOT NULL,
          final_response_json TEXT NOT NULL,
          verification_result_json TEXT NOT NULL,
          model_configuration_json TEXT NOT NULL,
          skill_execution_json TEXT,
          user_feedback_json TEXT,
          contains_sensitive_data INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_replay_traces_turn '
        'ON replay_traces(agent_turn_id)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_replay_traces_created '
        'ON replay_traces(created_at)');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS evaluation_scenarios (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          user_request TEXT NOT NULL,
          mock_state_json TEXT NOT NULL DEFAULT '{}',
          expected_domains_json TEXT NOT NULL DEFAULT '[]',
          required_tools_json TEXT NOT NULL DEFAULT '[]',
          forbidden_tools_json TEXT NOT NULL DEFAULT '[]',
          required_outputs_json TEXT NOT NULL DEFAULT '[]',
          expected_skill TEXT,
          expected_entities_json TEXT NOT NULL DEFAULT '[]',
          expected_memory_ids_json TEXT NOT NULL DEFAULT '[]',
          maximum_tool_calls INTEGER NOT NULL DEFAULT 24,
          tags_json TEXT NOT NULL DEFAULT '[]',
          source_trace_id TEXT,
          created_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS evaluation_results (
          id TEXT PRIMARY KEY,
          scenario_id TEXT NOT NULL,
          passed INTEGER NOT NULL,
          overall_score REAL NOT NULL,
          metrics_json TEXT NOT NULL DEFAULT '{}',
          failures_json TEXT NOT NULL DEFAULT '[]',
          created_at TEXT NOT NULL,
          FOREIGN KEY(scenario_id) REFERENCES evaluation_scenarios(id)
      )
    ''');
  }

  /// Schema v17: machine-readable parameters on a behavior rule, so typed
  /// rules can be enforced in code (notification quiet hours, default event
  /// lead times) instead of only read as prompt text.
  static Future<void> _applyV17(Database db) async {
    // Both tables: a proposal that carries parameters must keep them when
    // the user approves it, or an approved quiet-hours rule would silently
    // degrade to prompt text.
    for (final table in ['agent_behaviors', 'behavior_change_requests']) {
      final columns = await db.rawQuery('PRAGMA table_info($table)');
      // Empty means the table does not exist in this database yet (very old
      // schemas predate it); it will be created with the column.
      if (columns.isEmpty) continue;
      if (!columns.any((c) => c['name'] == 'params')) {
        await db.execute('ALTER TABLE $table ADD COLUMN params TEXT');
      }
    }
  }

  /// Schema v18: hardened background execution and behavior governance.
  ///
  /// `job_runs` becomes the execution ledger (one row per *scheduled
  /// occurrence*, not per attempt-that-happened-to-start), which is what
  /// makes duplicate execution impossible: the unique index on
  /// (job_id, scheduled_for) is the lock. `scheduled_jobs` gains the
  /// per-job policy the runner needs, and `agent_behaviors` gains the
  /// governance metadata conflict resolution and expiry depend on.
  static Future<void> _applyV18(Database db) async {
    // Very old databases (and the migration tests' hand-built fixtures)
    // predate some of these tables; a missing table is created with the
    // right shape later, so skip rather than fail the whole upgrade.
    Future<bool> hasTable(String table) async {
      final rows = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
          [table]);
      return rows.isNotEmpty;
    }

    Future<void> addColumns(
        String table, Map<String, String> columns) async {
      final existing = await db.rawQuery('PRAGMA table_info($table)');
      if (existing.isEmpty) return;
      final names = existing.map((c) => c['name']).toSet();
      for (final entry in columns.entries) {
        if (!names.contains(entry.key)) {
          await db.execute(
              'ALTER TABLE $table ADD COLUMN ${entry.key} ${entry.value}');
        }
      }
    }

    await addColumns('job_runs', {
      // The occurrence this run belongs to - the idempotency key.
      'scheduled_for': 'TEXT',
      'attempt': 'INTEGER NOT NULL DEFAULT 1',
      // While held and unexpired, no other isolate may take this run.
      'lease_until': 'TEXT',
      'trigger_source': 'TEXT',
      'behavior_version': 'INTEGER',
      'input_hash': 'TEXT',
      'model_id': 'TEXT',
      'tokens_in': 'INTEGER',
      'tokens_out': 'INTEGER',
      'error_code': 'TEXT',
    });
    if (await hasTable('job_runs')) {
      // NULL scheduled_for values stay distinct under SQLite's unique-index
      // semantics, so legacy rows never collide with each other.
      await db.execute('CREATE UNIQUE INDEX IF NOT EXISTS '
          'idx_job_runs_occurrence ON job_runs(job_id, scheduled_for)');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_job_runs_status '
          'ON job_runs(status)');
    }

    await addColumns('scheduled_jobs', {
      'permissions_json': 'TEXT',
      "behavior_mode": "TEXT NOT NULL DEFAULT 'live'",
      'behavior_snapshot': 'TEXT',
      'behavior_version': 'INTEGER',
      "missed_run_policy": "TEXT NOT NULL DEFAULT 'run_once_now'",
      'timeout_seconds': 'INTEGER NOT NULL DEFAULT 300',
      'max_attempts': 'INTEGER NOT NULL DEFAULT 3',
    });

    await addColumns('agent_behaviors', {
      'params_schema_version': 'INTEGER NOT NULL DEFAULT 1',
      "enforcement_mode": "TEXT NOT NULL DEFAULT 'advisory'",
      "source": "TEXT NOT NULL DEFAULT 'inferred'",
      'confidence': 'REAL NOT NULL DEFAULT 0.5',
      'scope_intent': 'TEXT',
      'conflict_group': 'TEXT',
      'version': 'INTEGER NOT NULL DEFAULT 1',
      'evidence_count': 'INTEGER NOT NULL DEFAULT 1',
      'negative_feedback_count': 'INTEGER NOT NULL DEFAULT 0',
      'last_used_at': 'TEXT',
      'last_confirmed_at': 'TEXT',
      'expires_at': 'TEXT',
    });
    // Rules that predate provenance were saved because the user asked for
    // them, so mark them explicit and confirmed rather than leaving them
    // looking like low-confidence guesses that expiry might sweep up.
    if (await hasTable('agent_behaviors')) {
      await db.execute("UPDATE agent_behaviors SET source = 'explicit', "
          'confidence = 1.0, last_confirmed_at = created_at '
          "WHERE approved_by_user = 1 OR created_by = 'user'");
    }

    await db.execute('''
      CREATE TABLE IF NOT EXISTS diagnostic_events (
          id TEXT PRIMARY KEY,
          code TEXT NOT NULL,
          severity TEXT NOT NULL DEFAULT 'info',
          message TEXT NOT NULL,
          context_json TEXT NOT NULL DEFAULT '{}',
          created_at TEXT NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_diagnostics_created '
        'ON diagnostic_events(created_at)');
  }

  /// Schema v19: memory lifecycle and provenance, creation provenance on
  /// agent-created records, conversation capsules, and the token-calibration
  /// ledger.
  ///
  /// The theme is the same everywhere: a row must say where it came from.
  /// A memory that cannot name its source cannot be trusted over a tool
  /// result; a task that cannot name the job and source item that created it
  /// is the "unexplained daily task" the user has no way to reason about.
  static Future<void> _applyV19(Database db) async {
    Future<void> addColumns(String table, Map<String, String> columns) async {
      // A missing table is created with the right shape elsewhere; very old
      // databases (and the migration tests' fixtures) predate several of
      // these, and ALTERing one that does not exist fails the whole upgrade.
      final existing = await db.rawQuery('PRAGMA table_info($table)');
      if (existing.isEmpty) return;
      final names = existing.map((column) => column['name']).toSet();
      for (final entry in columns.entries) {
        if (!names.contains(entry.key)) {
          await db.execute(
              'ALTER TABLE $table ADD COLUMN ${entry.key} ${entry.value}');
        }
      }
    }

    // Memory lifecycle: what kind of claim this is, where it came from,
    // when it applies, and what it replaced.
    await addColumns('agent_memories', {
      'memory_kind': 'TEXT',
      "provenance": "TEXT NOT NULL DEFAULT 'deterministic_inference'",
      'observed_at': 'TEXT',
      'valid_from': 'TEXT',
      'valid_until': 'TEXT',
      'last_confirmed_at': 'TEXT',
      'topic_scope': 'TEXT',
      'supersedes_memory_id': 'TEXT',
      'contradicted_by_memory_id': 'TEXT',
      'reinforcement_count': 'INTEGER NOT NULL DEFAULT 1',
    });
    final memoryColumns = await db.rawQuery('PRAGMA table_info(agent_memories)');
    if (memoryColumns.isNotEmpty) {
      // Rows written before provenance existed came from the deterministic
      // candidate generator, which only ever derived them from application
      // state - so backfilling them as inferences is accurate, not
      // optimistic.
      await db.execute('UPDATE agent_memories SET observed_at = created_at '
          'WHERE observed_at IS NULL');
      await db.execute('UPDATE agent_memories SET valid_from = created_at '
          'WHERE valid_from IS NULL');
      await db.execute("UPDATE agent_memories SET provenance = 'user_statement', "
          'last_confirmed_at = updated_at WHERE user_confirmed = 1');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_agent_memories_topic '
          'ON agent_memories(topic_scope)');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_agent_memories_validity '
          'ON agent_memories(valid_until)');
    }

    // Creation provenance. Every record the agent creates records the job,
    // run, tool call and source item behind it, so the UI can say "created
    // by Daily Email Digest from 'Project deadline changed'" and offer undo.
    const provenance = <String, String>{
      'origin_type': 'TEXT',
      'origin_job_id': 'TEXT',
      'origin_run_id': 'TEXT',
      'origin_tool_call_id': 'TEXT',
      'source_record_id': 'TEXT',
      'authorization_source': 'TEXT',
      'origin_reason': 'TEXT',
      'undone_at': 'TEXT',
    };
    for (final table in [
      'tasks',
      'reminders',
      'schedule_items',
      'scheduled_jobs',
      'dynamic_screens',
    ]) {
      await addColumns(table, provenance);
    }
    for (final table in ['tasks', 'reminders', 'schedule_items']) {
      final columns = await db.rawQuery('PRAGMA table_info($table)');
      if (columns.isEmpty) continue;
      await db.execute('CREATE INDEX IF NOT EXISTS idx_${table}_origin_run '
          'ON $table(origin_run_id)');
    }

    // Structured conversation capsules: semantic compaction of a topic that
    // has grown too large to replay verbatim.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS conversation_capsules (
          id TEXT PRIMARY KEY,
          conversation_id TEXT NOT NULL,
          topic_id TEXT NOT NULL,
          user_goal TEXT NOT NULL,
          confirmed_decisions_json TEXT NOT NULL DEFAULT '[]',
          current_constraints_json TEXT NOT NULL DEFAULT '[]',
          completed_actions_json TEXT NOT NULL DEFAULT '[]',
          unresolved_questions_json TEXT NOT NULL DEFAULT '[]',
          important_entity_ids_json TEXT NOT NULL DEFAULT '[]',
          evidence_refs_json TEXT NOT NULL DEFAULT '[]',
          last_user_correction TEXT,
          covers_through_message_id TEXT,
          turn_count INTEGER NOT NULL DEFAULT 0,
          is_stale INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
      )
    ''');
    await db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_capsules_conversation_topic '
        'ON conversation_capsules(conversation_id, topic_id)');

    // Token-estimation calibration: measured estimate-vs-actual per model,
    // so the estimator learns each provider's tokenizer instead of assuming
    // one ratio fits Anthropic, llama.cpp and Gemma alike.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS token_calibration_samples (
          id TEXT PRIMARY KEY,
          model_identifier TEXT NOT NULL,
          estimated_input INTEGER NOT NULL,
          actual_input INTEGER NOT NULL,
          estimated_output INTEGER NOT NULL DEFAULT 0,
          actual_output INTEGER NOT NULL DEFAULT 0,
          structured_ratio REAL NOT NULL DEFAULT 0.5,
          created_at TEXT NOT NULL
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_token_calibration_model '
        'ON token_calibration_samples(model_identifier, created_at)');

    // Service circuit breakers: one row per (service, account) so a broken
    // mail account stops being hammered without taking the others down.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS service_circuits (
          service TEXT NOT NULL,
          account_id TEXT NOT NULL DEFAULT '',
          consecutive_failures INTEGER NOT NULL DEFAULT 0,
          circuit_state TEXT NOT NULL DEFAULT 'closed',
          failure_kind TEXT,
          last_success_at TEXT,
          last_failure_at TEXT,
          retry_after TEXT,
          notified_at TEXT,
          updated_at TEXT NOT NULL,
          PRIMARY KEY(service, account_id)
      )
    ''');

    // Behaviour trigger ledger: one row per (behaviour, event) firing, so
    // the same event cannot fire the same rule twice and daily caps are
    // enforceable across process restarts.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS behavior_trigger_firings (
          id TEXT PRIMARY KEY,
          behavior_id TEXT NOT NULL,
          event_id TEXT NOT NULL,
          job_run_id TEXT,
          effects_created INTEGER NOT NULL DEFAULT 0,
          fired_on TEXT NOT NULL,
          created_at TEXT NOT NULL
      )
    ''');
    await db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_trigger_firings_event '
        'ON behavior_trigger_firings(behavior_id, event_id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_trigger_firings_day '
        'ON behavior_trigger_firings(behavior_id, fired_on)');
  }

  /// Schema v20: the daily planning board.
  ///
  /// A plan entry is *when the user intends to do something*, which is not
  /// the same fact as a task's due date (a deadline) or a calendar event (a
  /// commitment) - so it is its own row rather than another column on those.
  /// That separation is what lets a task due Friday be planned for Tuesday
  /// morning, and lets today's plan be rearranged without touching a single
  /// deadline.
  ///
  /// [title] is a snapshot: it renders the board without a join and gives
  /// ad-hoc blocks ("deep work") a name of their own. The live task or
  /// reminder stays the source of truth for status - see
  /// `DayPlanRepository.viewsForDay`.
  static Future<void> _applyV20(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS day_plan_entries (
          id TEXT PRIMARY KEY,
          plan_date TEXT NOT NULL,
          source_type TEXT NOT NULL,
          source_id TEXT,
          title TEXT NOT NULL,
          start_minute INTEGER NOT NULL,
          duration_minutes INTEGER NOT NULL DEFAULT 30,
          status TEXT NOT NULL DEFAULT 'planned',
          notes TEXT,
          created_by TEXT NOT NULL DEFAULT 'user',
          origin_type TEXT,
          origin_job_id TEXT,
          origin_run_id TEXT,
          origin_tool_call_id TEXT,
          source_record_id TEXT,
          authorization_source TEXT,
          origin_reason TEXT,
          undone_at TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_day_plan_date '
        'ON day_plan_entries(plan_date, start_minute)');
    // One card per task per day: planning something already on the board
    // moves it instead of duplicating it. Partial, so ad-hoc blocks (no
    // source) can repeat as often as the user likes.
    await db.execute('CREATE UNIQUE INDEX IF NOT EXISTS idx_day_plan_source '
        'ON day_plan_entries(plan_date, source_type, source_id) '
        'WHERE source_id IS NOT NULL');
  }

  /// Schema v21: messages from chat apps (WhatsApp first), captured from
  /// notifications, imported from a chat export, or handed over deliberately
  /// by the user.
  ///
  /// **One table with a `channel` column, not one table per app.** The
  /// Android notification listener that reads WhatsApp reads Signal,
  /// Telegram and SMS through the identical API, so a per-app table would
  /// mean re-implementing digest, dedupe and triggers four times for no new
  /// behaviour. `email_items` stays separate on purpose: mail has a subject,
  /// a thread and an account, and folding two different shapes into one row
  /// would put a nullable column on every read.
  ///
  /// **`external_id` is a content hash, not an app-supplied id.** WhatsApp
  /// re-posts one notification per chat carrying *every* recent message in
  /// that chat, so the same message arrives many times under the same
  /// notification key. The hash is over channel + conversation + sender +
  /// timestamp + body, which is what makes "the same message" mean the same
  /// thing whether it came from a notification, an export, or a share. The
  /// unique index is partial because a manually pasted message has no hash
  /// to compute and two identical pastes are two deliberate acts.
  ///
  /// **`referenced` is not `digested`.** Digesting is Exa working through a
  /// backlog; referencing is the user pointing at one message and asking
  /// about it. A referenced message must survive being digested, or "what
  /// did Alice mean by that?" loses its subject the moment a background job
  /// runs.
  static Future<void> _applyV21(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS inbound_messages (
          id TEXT PRIMARY KEY,
          channel TEXT NOT NULL,
          conversation_id TEXT NOT NULL,
          conversation_title TEXT,
          is_group INTEGER NOT NULL DEFAULT 0,
          sender TEXT,
          body TEXT NOT NULL,
          summary TEXT,
          sent_at TEXT,
          source TEXT NOT NULL DEFAULT 'notification',
          external_id TEXT,
          package_name TEXT,
          can_reply INTEGER NOT NULL DEFAULT 0,
          digested INTEGER NOT NULL DEFAULT 0,
          referenced INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_inbound_created '
        'ON inbound_messages(created_at)');
    // The digest queue is read as "undigested, oldest first" on every sync
    // and every trigger firing, which is the one query that runs whether or
    // not the user is looking at the app.
    await db.execute('CREATE INDEX IF NOT EXISTS idx_inbound_digested '
        'ON inbound_messages(digested, created_at)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_inbound_conversation '
        'ON inbound_messages(channel, conversation_id, sent_at)');
    await db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_inbound_external '
        'ON inbound_messages(external_id) WHERE external_id IS NOT NULL');
  }

  /// Schema v22: per-job notification muting.
  ///
  /// A column on the job rather than a notification rule: quiet hours are a
  /// time-of-day preference over every surface at once, and the thing users
  /// actually want here is "this one two-minute sync must stop buzzing me",
  /// which a rule cannot say. Defaults to 0, so every existing job keeps
  /// notifying exactly as it did.
  static Future<void> _applyV22(Database db) async {
    final existing = await db.rawQuery('PRAGMA table_info(scheduled_jobs)');
    if (existing.isEmpty) return; // created with the column on fresh installs
    if (existing.any((c) => c['name'] == 'mute_notifications')) return;
    await db.execute('ALTER TABLE scheduled_jobs ADD COLUMN '
        'mute_notifications INTEGER NOT NULL DEFAULT 0');
  }

  /// Schema v23: agent-defined data collections, so a built feature (notes,
  /// an expense log) owns real records instead of borrowing the task list.
  /// Collections are rows describing their fields; records hold field
  /// values as JSON. Purely additive, so safe on any installed version.
  static Future<void> _applyV23(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS user_collections (
          name TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          fields_json TEXT NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS user_records (
          id TEXT PRIMARY KEY,
          collection TEXT NOT NULL,
          fields_json TEXT NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
      )
    ''');
    // Serves the one hot read: every screen render over a collection
    // fetches its records by collection name.
    await db.execute('CREATE INDEX IF NOT EXISTS '
        'idx_user_records_collection ON user_records(collection)');
  }

  /// Schema v24: raise the job backstop timeout so a background turn on a
  /// slow local model is not killed mid-request (one model call alone may
  /// now take up to 15 minutes). Only rows still on the old default move;
  /// a timeout somebody chose explicitly is kept.
  static Future<void> _applyV24(Database db) async {
    // Fixture databases older than v17 (the migration tests) have no
    // scheduled_jobs yet; it is created with the new default later, so
    // there is nothing to move.
    final rows = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
        ['scheduled_jobs']);
    if (rows.isEmpty) return;
    await db.execute('UPDATE scheduled_jobs SET timeout_seconds = 1800 '
        'WHERE timeout_seconds = 300');
  }

  /// Schema v25: message media — the photos and voice notes a captured chat
  /// message carries as sidecar files next to the spool.
  ///
  /// Media gets its own table rather than columns on `inbound_messages`
  /// because one message can carry several items (up to the Kotlin capture
  /// cap) and they are listed, deduped and pruned per item, not per message.
  ///
  /// **`inbound_messages.body` stays `TEXT NOT NULL`.** A media-only message
  /// stores an empty body and carries its human note in `summary`: making the
  /// column nullable would mean a table rebuild to change one column's
  /// nullability, for a value every reader would then have to null-check —
  /// while an empty string is already a complete answer to "what text did
  /// this message have".
  ///
  /// Dedupe is index-enforced (`UNIQUE(message_id, content_hash)`) rather
  /// than select-then-insert, for the same reason `external_id` is in v21:
  /// MessagingStyle re-posts every recent message, so "not there yet, insert
  /// it" is a race the notification storm wins constantly, and a duplicate
  /// row here would mean counting the same photo twice.
  static Future<void> _applyV25(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS inbound_media (
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
    // Two spool lines naming the same media for one message must collapse to
    // one row — this index is what makes that happen under concurrency.
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS '
      'inbound_media_message_hash ON inbound_media(message_id, content_hash)',
    );
    // Two *messages* sharing one photo produce two rows over one file path;
    // the lifetime check ("is anyone else still referencing this file?")
    // runs on this column on every delete and prune.
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_inbound_media_hash '
      'ON inbound_media(content_hash)',
    );
    // The orphan sweep and retention prune both walk media by age.
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_inbound_media_created '
      'ON inbound_media(created_at)',
    );
  }

  /// Schema v26: retry state for the voice-note transcription pass.
  ///
  /// `transcript_text` was reserved in v25 precisely so this day would need
  /// no table rebuild — but a text column alone cannot answer the questions
  /// a budgeted, retried, deduplicated pass has to ask between runs: which
  /// rows have never been offered ("none"), which the endpoint failed on and
  /// how many times ("failed" + `transcript_attempts`, the cap that stops a
  /// dead endpoint being hammered per drain), which are terminal and must
  /// never be offered again ("empty" / "unsupported"), and when the words
  /// landed (`transcribed_at`, so a stale transcript is explainable). Without
  /// these columns every pass would re-guess state from whether the text
  /// happens to be null, and a silent voice note would be transcribed again
  /// on every drain.
  ///
  /// `ALTER TABLE ... ADD COLUMN ... NOT NULL DEFAULT` is the whole upgrade:
  /// SQLite fills existing rows with the default, so media captured before
  /// this build reads back as never-offered — which is exactly true. The
  /// index serves the pass's one hot query (`pendingTranscriptions`: audio
  /// rows by status, oldest first); `kind` leads because a media table is
  /// overwhelmingly photos and the pass never asks for those.
  static Future<void> _applyV26(Database db) async {
    await db.execute('ALTER TABLE inbound_media ADD COLUMN '
        "transcript_status TEXT NOT NULL DEFAULT 'none'");
    await db.execute('ALTER TABLE inbound_media ADD COLUMN '
        'transcript_attempts INTEGER NOT NULL DEFAULT 0');
    await db.execute(
        'ALTER TABLE inbound_media ADD COLUMN transcribed_at TEXT');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_inbound_media_transcript '
      'ON inbound_media(kind, transcript_status)',
    );
  }

  /// Schema v5: high-risk phone-calendar writes the user must approve
  /// before they touch the device calendar (durably logged so they are
  /// never silently done nor silently lost).
  static Future<void> _applyV5(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pending_calendar_events (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          start_at TEXT NOT NULL,
          end_at TEXT,
          location TEXT,
          description TEXT,
          status TEXT NOT NULL DEFAULT 'Pending',
          external_event_id TEXT,
          source TEXT DEFAULT 'agent',
          error_message TEXT,
          created_at TEXT NOT NULL,
          decided_at TEXT
      )
    ''');
  }
}
