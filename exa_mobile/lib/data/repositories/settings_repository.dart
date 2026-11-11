import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import '../database/app_database.dart';
import '../models/autonomy_level.dart';
import '../secure_storage.dart';

/// Non-sensitive settings live in the SQLite `settings` table; secrets
/// (the AI API key) live in platform secure storage and never touch the DB.
class SettingsRepository {
  SettingsRepository(this._database, {FlutterSecureStorage? secureStorage})
      : _secureStorage = secureStorage ?? appSecureStorage;

  final AppDatabase _database;
  final FlutterSecureStorage _secureStorage;

  static const _apiKeyStorageKey = 'anthropic_api_key';
  static const _deepSeekApiKeyStorageKey = 'deepseek_api_key';
  static const _localApiKeyStorageKey = 'local_api_key';
  static const _hfTokenStorageKey = 'huggingface_token';
  static const modelSettingKey = 'ai_model';
  static const defaultModel = 'claude-opus-4-8';

  static const availableModels = [
    'claude-opus-4-8',
    'claude-fable-5',
    'claude-sonnet-4-6',
    'claude-haiku-4-5',
  ];

  // ------------------------------------------------------ AI provider --

  static const aiProviderKey = 'ai_provider';
  static const aiLocalBaseUrlKey = 'ai_local_base_url';
  static const aiLocalModelKey = 'ai_local_model';
  static const aiLocalVisionKey = 'ai_local_vision';
  static const aiLocalContextKey = 'ai_local_context_tokens';

  /// Context assumed for a self-hosted endpoint when the user has not said
  /// otherwise.
  ///
  /// Everything the app spends on framing is a fraction of this, and at 16k
  /// the shares are too tight to replay a useful conversation - two of Exa's
  /// own replies fill the 20% history budget on their own.
  ///
  /// This assumption must not EXCEED the `--ctx-size` the server was started
  /// with: a request over the real limit is rejected outright rather than
  /// degraded, so guessing high turns a thinner answer into a dead turn.
  /// Only a starting point - the Settings > AI provider field overrides it,
  /// and a server started with a smaller context needs that set.
  static const int defaultLocalContextTokens = 32768;
  static const aiOnDeviceModelPathKey = 'ai_on_device_model_path';

  /// Stable [OnDeviceModel.id] of the active downloaded (catalog) model, or
  /// null when none / a sideloaded file model is active. Kept alongside
  /// [aiOnDeviceModelPathKey] so the client can re-activate the right model
  /// after a restart (the plugin only holds the active model in memory).
  static const aiOnDeviceModelIdKey = 'ai_on_device_model_id';

  /// Selectable AI backends. `remote` = Anthropic API; `deepseek` = the
  /// DeepSeek cloud API; `local` = an OpenAI-compatible server
  /// (Ollama/LM Studio/llama.cpp); `on_device` = an embedded model running
  /// inside the app.
  static const providerRemote = 'remote';
  static const providerDeepSeek = 'deepseek';
  static const providerLocal = 'local';
  static const providerOnDevice = 'on_device';
  static const defaultProvider = providerRemote;

  /// Whether [provider] is a cloud API this app holds a key for - the two
  /// backends that can do the full job (tools, background jobs) from
  /// anywhere, as opposed to needing a reachable server or plugin channels.
  static bool isHostedProvider(String provider) =>
      provider == providerRemote || provider == providerDeepSeek;

  /// Sensible default for a host Ollama reached from an Android emulator.
  static const defaultLocalBaseUrl = 'http://10.0.2.2:11434';
  static const defaultLocalModel = 'llama3.1';

  Future<String> getAiProvider() async =>
      await getValue(aiProviderKey) ?? defaultProvider;

  Future<void> setAiProvider(String provider) =>
      setValue(aiProviderKey, provider);

  Future<String> getLocalBaseUrl() async =>
      await getValue(aiLocalBaseUrlKey) ?? defaultLocalBaseUrl;

  Future<void> setLocalBaseUrl(String url) =>
      setValue(aiLocalBaseUrlKey, url);

  Future<String> getLocalModel() async =>
      await getValue(aiLocalModelKey) ?? defaultLocalModel;

  Future<void> setLocalModel(String model) =>
      setValue(aiLocalModelKey, model);

  /// Whether the model loaded on the local server can read images.
  ///
  /// This can't be detected - the same endpoint serves whatever model the user
  /// loaded - so it's a declaration, not a probe. Off by default because most
  /// local models are text-only and posting image parts to one usually fails
  /// the whole request rather than degrading.
  Future<bool> getLocalVision() async =>
      await getValue(aiLocalVisionKey) == 'true';

  Future<void> setLocalVision(bool enabled) =>
      setValue(aiLocalVisionKey, enabled ? 'true' : 'false');

  /// The `--ctx-size` the user's server was started with.
  Future<int> getLocalContextTokens() async {
    final raw = await getValue(aiLocalContextKey);
    final parsed = int.tryParse(raw ?? '');
    if (parsed == null) return defaultLocalContextTokens;
    return parsed.clamp(2048, 1000000);
  }

  Future<void> setLocalContextTokens(int tokens) =>
      setValue(aiLocalContextKey, '$tokens');

  /// Bearer token for the local server, or null when it needs none.
  ///
  /// Plain Ollama and llama.cpp ignore it, but the moment the server is put
  /// behind anything - an OpenAI-compatible gateway, LM Studio with auth on,
  /// a tunnel like ngrok with an access token - it becomes required, and
  /// without it every local turn fails with a 401 the user cannot fix from
  /// this app. It is a credential, so secure storage, and read with the same
  /// tolerance for a store the platform can no longer decrypt as [getApiKey].
  ///
  /// One key serves both uses of the local endpoint: the Local server
  /// provider, and the vision model that stands in for a blind provider (see
  /// [getLocalVision]) - the same server answers both.
  Future<String?> getLocalApiKey() async {
    try {
      return await _secureStorage.read(key: _localApiKeyStorageKey);
    } catch (e) {
      if (isDecryptionFailure(e)) return null;
      rethrow;
    }
  }

  Future<void> setLocalApiKey(String? key) async {
    if (key == null || key.isEmpty) {
      await _secureStorage.delete(key: _localApiKeyStorageKey);
    } else {
      await _secureStorage.write(key: _localApiKeyStorageKey, value: key);
    }
  }

  Future<bool> hasLocalApiKey() async {
    final key = await getLocalApiKey();
    return key != null && key.isNotEmpty;
  }

  // -------------------------------------------------------- DeepSeek --

  static const aiDeepSeekModelKey = 'ai_deepseek_model';
  static const aiDeepSeekBaseUrlKey = 'ai_deepseek_base_url';

  /// The two models DeepSeek's API serves: `deepseek-chat` answers directly,
  /// `deepseek-reasoner` thinks first (slower, and its reasoning is billed as
  /// output). The list is a convenience for the picker, not a restriction -
  /// [setDeepSeekModel] takes any id, so a model released after this build
  /// can still be typed in.
  static const deepSeekModels = [
    'deepseek-chat',
    'deepseek-reasoner',
  ];
  static const defaultDeepSeekModel = 'deepseek-chat';
  static const defaultDeepSeekBaseUrl = 'https://api.deepseek.com';

  Future<String> getDeepSeekModel() async =>
      await getValue(aiDeepSeekModelKey) ?? defaultDeepSeekModel;

  Future<void> setDeepSeekModel(String model) =>
      setValue(aiDeepSeekModelKey, model);

  /// Non-default only when the user routes DeepSeek through a proxy.
  Future<String> getDeepSeekBaseUrl() async {
    final stored = await getValue(aiDeepSeekBaseUrlKey);
    return (stored == null || stored.trim().isEmpty)
        ? defaultDeepSeekBaseUrl
        : stored.trim();
  }

  Future<void> setDeepSeekBaseUrl(String url) =>
      setValue(aiDeepSeekBaseUrlKey, url);

  /// The DeepSeek key, kept in secure storage next to the Anthropic one and
  /// read with the same tolerance for a store the platform can no longer
  /// decrypt (reinstall, backup restore) - see [getApiKey].
  Future<String?> getDeepSeekApiKey() async {
    try {
      return await _secureStorage.read(key: _deepSeekApiKeyStorageKey);
    } catch (e) {
      if (isDecryptionFailure(e)) return null;
      rethrow;
    }
  }

  Future<void> setDeepSeekApiKey(String? key) async {
    if (key == null || key.isEmpty) {
      await _secureStorage.delete(key: _deepSeekApiKeyStorageKey);
    } else {
      await _secureStorage.write(key: _deepSeekApiKeyStorageKey, value: key);
    }
  }

  Future<bool> hasDeepSeekApiKey() async {
    final key = await getDeepSeekApiKey();
    return key != null && key.isNotEmpty;
  }

  /// The key for whichever hosted provider is selected, so callers that just
  /// need "the credential for this turn" don't each re-derive it.
  Future<String?> getApiKeyForProvider(String provider) async =>
      provider == providerDeepSeek ? getDeepSeekApiKey() : getApiKey();

  Future<String?> getOnDeviceModelPath() => getValue(aiOnDeviceModelPathKey);

  Future<void> setOnDeviceModelPath(String? path) =>
      setValue(aiOnDeviceModelPathKey, path);

  Future<String?> getOnDeviceModelId() => getValue(aiOnDeviceModelIdKey);

  Future<void> setOnDeviceModelId(String? id) =>
      setValue(aiOnDeviceModelIdKey, id);

  /// HuggingFace access token for downloading gated models (Gemma, etc.).
  /// Stored in secure storage - it's a credential, never in the DB.
  Future<String?> getHuggingFaceToken() =>
      _secureStorage.read(key: _hfTokenStorageKey);

  Future<void> setHuggingFaceToken(String? token) async {
    if (token == null || token.isEmpty) {
      await _secureStorage.delete(key: _hfTokenStorageKey);
    } else {
      await _secureStorage.write(key: _hfTokenStorageKey, value: token);
    }
  }

  Future<String?> getValue(String key) async {
    final rows = await _database.db
        .query('settings', where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> setValue(String key, String? value) async {
    await _database.db.insert(
      'settings',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> removeValue(String key) async {
    await _database.db.delete('settings', where: 'key = ?', whereArgs: [key]);
  }

  /// Keys starting with [prefix], for the few stores kept here under one.
  Future<List<String>> keysWithPrefix(String prefix) async {
    final rows = await _database.db.query(
      'settings',
      columns: ['key'],
      where: 'substr(key, 1, ?) = ?',
      whereArgs: [prefix.length, prefix],
    );
    return [for (final row in rows) row['key'] as String];
  }

  Future<String> getModel() async =>
      await getValue(modelSettingKey) ?? defaultModel;

  Future<void> setModel(String model) => setValue(modelSettingKey, model);

  /// The stored API key, or null when there is none.
  ///
  /// A store the platform can no longer decrypt (reinstall, backup restore)
  /// reads as "no key" rather than throwing: every caller already handles a
  /// missing key with a clear "add one in Settings" message, which is
  /// exactly the right instruction here too.
  Future<String?> getApiKey() async {
    try {
      return await _secureStorage.read(key: _apiKeyStorageKey);
    } catch (e) {
      if (isDecryptionFailure(e)) return null;
      rethrow;
    }
  }

  Future<void> setApiKey(String? key) async {
    if (key == null || key.isEmpty) {
      await _secureStorage.delete(key: _apiKeyStorageKey);
    } else {
      await _secureStorage.write(key: _apiKeyStorageKey, value: key);
    }
  }

  Future<bool> hasApiKey() async {
    final key = await getApiKey();
    return key != null && key.isNotEmpty;
  }

  // ------------------------------------------- phone-calendar sync --

  static const calendarSyncEventsKey = 'calendar_sync.events';
  static const calendarSyncTasksKey = 'calendar_sync.tasks';

  /// When on, events created in Exa (by the user or the agent) are also
  /// added to the phone calendar, and edits/deletes follow. Off by default
  /// so the OS calendar-permission prompt only ever appears after the user
  /// opts in.
  Future<bool> isCalendarSyncEventsEnabled() async =>
      await getValue(calendarSyncEventsKey) == 'true';

  Future<void> setCalendarSyncEventsEnabled(bool enabled) =>
      setValue(calendarSyncEventsKey, enabled ? 'true' : 'false');

  /// Same as [isCalendarSyncEventsEnabled], for tasks with a due date.
  Future<bool> isCalendarSyncTasksEnabled() async =>
      await getValue(calendarSyncTasksKey) == 'true';

  Future<void> setCalendarSyncTasksEnabled(bool enabled) =>
      setValue(calendarSyncTasksKey, enabled ? 'true' : 'false');

  // ----------------------------------------------- agent permissions --

  /// All permission groups default to enabled; the user can switch any
  /// group off in Settings > Agent permissions (Phase 7).
  Future<bool> isPermissionEnabled(String permission) async {
    final value = await getValue('perm.$permission');
    return value != 'false';
  }

  Future<void> setPermissionEnabled(String permission, bool enabled) =>
      setValue('perm.$permission', enabled ? 'true' : 'false');

  static const autonomyLevelKey = 'agent.autonomy_level';

  /// v3 runs fully autonomous by default - no confirmation prompts, the
  /// switches above not applied. `guarded` restores v2's behaviour.
  Future<AutonomyLevel> getAutonomyLevel() async =>
      AutonomyLevel.fromWire(await getValue(autonomyLevelKey));

  Future<void> setAutonomyLevel(AutonomyLevel level) =>
      setValue(autonomyLevelKey, level.wireName);

  // ---------------------------------------------- intelligence layer --

  static const longTermMemoryKey = 'memory.long_term_enabled';
  static const fullReplayTracesKey = 'replay.full_traces';

  /// Long-term memory (semantic/episodic/procedural/commitment writes) is
  /// on by default; the user can switch it off in Settings > Memory.
  Future<bool> isLongTermMemoryEnabled() async =>
      await getValue(longTermMemoryKey) != 'false';

  Future<void> setLongTermMemoryEnabled(bool enabled) =>
      setValue(longTermMemoryKey, enabled ? 'true' : 'false');

  /// Replay traces are redacted by default. Full traces (raw values, marked
  /// sensitive) are a local debugging opt-in.
  Future<bool> isFullReplayTracesEnabled() async =>
      await getValue(fullReplayTracesKey) == 'true';

  Future<void> setFullReplayTracesEnabled(bool enabled) =>
      setValue(fullReplayTracesKey, enabled ? 'true' : 'false');
}
