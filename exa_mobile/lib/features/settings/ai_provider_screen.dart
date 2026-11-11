import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;

import '../../data/repositories/settings_repository.dart';
import '../../services/ai_client/ai_client.dart';
import '../../services/ai_client/deepseek_client.dart';
import '../../services/ai_client/on_device_catalog.dart';
import '../../shared/providers.dart';
import 'on_device_models_controller.dart';

final aiProviderProvider = FutureProvider.autoDispose<String>(
    (ref) => ref.watch(settingsRepositoryProvider).getAiProvider());
final localBaseUrlProvider = FutureProvider.autoDispose<String>(
    (ref) => ref.watch(settingsRepositoryProvider).getLocalBaseUrl());
final localModelProvider = FutureProvider.autoDispose<String>(
    (ref) => ref.watch(settingsRepositoryProvider).getLocalModel());
final localVisionProvider = FutureProvider.autoDispose<bool>(
    (ref) => ref.watch(settingsRepositoryProvider).getLocalVision());
final localContextProvider = FutureProvider.autoDispose<int>(
    (ref) => ref.watch(settingsRepositoryProvider).getLocalContextTokens());
final hasLocalKeyProvider = FutureProvider.autoDispose<bool>(
    (ref) => ref.watch(settingsRepositoryProvider).hasLocalApiKey());
final deepSeekModelProvider = FutureProvider.autoDispose<String>(
    (ref) => ref.watch(settingsRepositoryProvider).getDeepSeekModel());
final deepSeekBaseUrlProvider = FutureProvider.autoDispose<String>(
    (ref) => ref.watch(settingsRepositoryProvider).getDeepSeekBaseUrl());
final hasDeepSeekKeyProvider = FutureProvider.autoDispose<bool>(
    (ref) => ref.watch(settingsRepositoryProvider).hasDeepSeekApiKey());

/// Human-readable label for a stored provider id, for the Settings subtitle.
String aiProviderLabel(String provider) => switch (provider) {
      SettingsRepository.providerDeepSeek => 'DeepSeek (cloud)',
      SettingsRepository.providerLocal => 'Local server',
      SettingsRepository.providerOnDevice => 'On-device (experimental)',
      _ => 'Anthropic (cloud)',
    };

class AiProviderScreen extends ConsumerWidget {
  const AiProviderScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = ref.watch(aiProviderProvider).value ??
        SettingsRepository.defaultProvider;
    final baseUrl = ref.watch(localBaseUrlProvider).value ??
        SettingsRepository.defaultLocalBaseUrl;
    final localModel = ref.watch(localModelProvider).value ??
        SettingsRepository.defaultLocalModel;
    final localVision = ref.watch(localVisionProvider).value ?? false;
    final localContext = ref.watch(localContextProvider).value ??
        SettingsRepository.defaultLocalContextTokens;
    final deepSeekModel = ref.watch(deepSeekModelProvider).value ??
        SettingsRepository.defaultDeepSeekModel;
    final deepSeekBaseUrl = ref.watch(deepSeekBaseUrlProvider).value ??
        SettingsRepository.defaultDeepSeekBaseUrl;
    final hasDeepSeekKey = ref.watch(hasDeepSeekKeyProvider).value ?? false;

    Future<void> setProvider(String? value) async {
      if (value == null) return;
      await ref.read(settingsRepositoryProvider).setAiProvider(value);
      ref.invalidate(aiProviderProvider);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('AI provider')),
      body: ListView(
        children: [
          const _Header('Provider'),
          RadioListTile<String>(
            value: SettingsRepository.providerRemote,
            // ignore: deprecated_member_use
            groupValue: provider,
            // ignore: deprecated_member_use
            onChanged: setProvider,
            title: const Text('Anthropic (cloud)'),
            subtitle: const Text(
                'Full capabilities: tools, images, and PDFs. Needs an API key.'),
          ),
          RadioListTile<String>(
            value: SettingsRepository.providerDeepSeek,
            // ignore: deprecated_member_use
            groupValue: provider,
            // ignore: deprecated_member_use
            onChanged: setProvider,
            title: const Text('DeepSeek (cloud)'),
            subtitle: const Text(
                'Tools, background work and streaming, at DeepSeek prices. '
                'Text only - no images or PDFs. Needs a DeepSeek API key.'),
          ),
          RadioListTile<String>(
            value: SettingsRepository.providerLocal,
            // ignore: deprecated_member_use
            groupValue: provider,
            // ignore: deprecated_member_use
            onChanged: setProvider,
            title: const Text('Local server'),
            subtitle: const Text(
                'An OpenAI-compatible server (Ollama, LM Studio, llama.cpp) '
                'on your machine or network. Supports tools.'),
          ),
          RadioListTile<String>(
            value: SettingsRepository.providerOnDevice,
            // ignore: deprecated_member_use
            groupValue: provider,
            // ignore: deprecated_member_use
            onChanged: setProvider,
            title: const Text('On-device (experimental)'),
            subtitle: const Text(
                'Runs inside the app, fully offline. No tool use, vision, or '
                'background briefings.'),
          ),
          const Divider(),
          if (provider == SettingsRepository.providerRemote)
            const _RemoteSection()
          else if (provider == SettingsRepository.providerDeepSeek)
            _DeepSeekSection(
                model: deepSeekModel,
                baseUrl: deepSeekBaseUrl,
                hasKey: hasDeepSeekKey)
          else if (provider == SettingsRepository.providerLocal)
            _LocalSection(
                baseUrl: baseUrl,
                model: localModel,
                vision: localVision,
                contextTokens: localContext)
          else
            const _OnDeviceSection(),
        ],
      ),
    );
  }
}

class _RemoteSection extends StatelessWidget {
  const _RemoteSection();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Header('Anthropic settings'),
        ListTile(
          leading: const Icon(Icons.key),
          title: const Text('API key & model'),
          subtitle: const Text(
              'Set the Anthropic API key and model on the Settings screen.'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.go('/settings'),
        ),
      ],
    );
  }
}

class _DeepSeekSection extends ConsumerWidget {
  const _DeepSeekSection({
    required this.model,
    required this.baseUrl,
    required this.hasKey,
  });

  final String model;
  final String baseUrl;
  final bool hasKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final custom = !SettingsRepository.deepSeekModels.contains(model);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Header('DeepSeek settings'),
        ListTile(
          leading: Icon(hasKey ? Icons.key : Icons.key_off,
              color: hasKey ? Colors.green : Colors.orange),
          title: Text(hasKey ? 'API key saved' : 'No API key set'),
          subtitle: const Text(
              'Stored in your device\'s secure storage and only sent to '
              'DeepSeek. Create one at platform.deepseek.com.'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async {
            final value = await _editText(context, 'DeepSeek API key', '',
                hint: 'sk-...', obscure: true, allowEmpty: true);
            if (value == null) return;
            await ref
                .read(settingsRepositoryProvider)
                .setDeepSeekApiKey(value.isEmpty ? null : value);
            ref.invalidate(hasDeepSeekKeyProvider);
          },
        ),
        ListTile(
          leading: const Icon(Icons.psychology_outlined),
          title: const Text('Model'),
          subtitle: Text(custom ? '$model (custom)' : model),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _pickModel(context, ref),
        ),
        ListTile(
          leading: const Icon(Icons.dns_outlined),
          title: const Text('API base URL'),
          subtitle: Text(baseUrl == SettingsRepository.defaultDeepSeekBaseUrl
              ? '$baseUrl (default)'
              : baseUrl),
          onTap: () async {
            final value = await _editText(context, 'API base URL', baseUrl,
                hint: SettingsRepository.defaultDeepSeekBaseUrl);
            if (value == null) return;
            await ref.read(settingsRepositoryProvider).setDeepSeekBaseUrl(value);
            ref.invalidate(deepSeekBaseUrlProvider);
          },
        ),
        ListTile(
          leading: const Icon(Icons.wifi_tethering),
          title: const Text('Test connection'),
          subtitle: const Text('Check the key works and list the models it '
              'can reach'),
          onTap: () => _testConnection(context, ref),
        ),
        const Divider(),
        const _ImageFallbackSection(),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Text(
              'DeepSeek is text-only, so PDFs are sent as extracted text and '
              'images go to whichever model can see them (above). Everything '
              'else - tools, scheduled briefings, background jobs - works the '
              'same as the cloud provider.',
              style: TextStyle(color: Colors.grey)),
        ),
      ],
    );
  }

  Future<void> _pickModel(BuildContext context, WidgetRef ref) async {
    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('DeepSeek model'),
        children: [
          for (final id in SettingsRepository.deepSeekModels)
            RadioListTile<String>(
              value: id,
              // ignore: deprecated_member_use
              groupValue: model,
              title: Text(id),
              subtitle: Text(id == 'deepseek-reasoner'
                  ? 'Thinks before answering: slower, and the reasoning is '
                      'billed as output.'
                  : 'The general chat model. The right default.'),
              // ignore: deprecated_member_use
              onChanged: (value) => Navigator.pop(dialogContext, value),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, _customSentinel),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Text('Enter a model id...'),
            ),
          ),
        ],
      ),
    );
    if (selected == null || !context.mounted) return;
    final id = selected == _customSentinel
        ? await _editText(context, 'DeepSeek model id', model,
            hint: 'deepseek-chat')
        : selected;
    if (id == null) return;
    await ref.read(settingsRepositoryProvider).setDeepSeekModel(id);
    ref.invalidate(deepSeekModelProvider);
  }

  /// A "type it yourself" escape hatch, so a model DeepSeek ships after this
  /// build is one text field away rather than an app update away.
  static const _customSentinel = '__custom__';

  Future<void> _testConnection(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final settings = ref.read(settingsRepositoryProvider);
    final key = await settings.getDeepSeekApiKey();
    if (key == null || key.isEmpty) {
      messenger.showSnackBar(const SnackBar(
          content: Text('Add a DeepSeek API key first.')));
      return;
    }
    final client = DeepSeekClient(baseUrl: baseUrl, apiKey: key);
    try {
      final models = await client.listModels();
      messenger.showSnackBar(SnackBar(
          content: Text(models.isEmpty
              ? 'Connected to DeepSeek.'
              : 'Connected to DeepSeek (${models.join(', ')}).')));
    } on AiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      client.dispose();
    }
  }
}

/// Where images go when the selected provider cannot see them.
///
/// It edits the *local server* settings, on purpose: the same declared vision
/// model serves the local provider and stands in for a blind one. Repeating
/// the two fields here is worth it - the alternative is switching provider to
/// Local server, configuring it, and switching back.
class _ImageFallbackSection extends ConsumerWidget {
  const _ImageFallbackSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vision = ref.watch(localVisionProvider).value ?? false;
    final baseUrl = ref.watch(localBaseUrlProvider).value ??
        SettingsRepository.defaultLocalBaseUrl;
    final model = ref.watch(localModelProvider).value ??
        SettingsRepository.defaultLocalModel;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Header('Images'),
        SwitchListTile(
          secondary: const Icon(Icons.image_outlined),
          value: vision,
          title: const Text('Send images to a local vision model'),
          subtitle: Text(vision
              ? 'Screenshots and image attachments go to the server below '
                  'instead of the cloud. The rest of the turn still runs on '
                  'DeepSeek.'
              : 'Off: images go to Anthropic when a key is set, and are '
                  'described as unreadable when it is not.'),
          isThreeLine: true,
          onChanged: (value) async {
            await ref.read(settingsRepositoryProvider).setLocalVision(value);
            ref.invalidate(localVisionProvider);
          },
        ),
        if (vision) ...[
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('Vision server URL'),
            subtitle: Text(baseUrl),
            onTap: () async {
              final value = await _editText(context, 'Server URL', baseUrl,
                  hint: 'http://10.0.2.2:11434');
              if (value == null) return;
              await ref.read(settingsRepositoryProvider).setLocalBaseUrl(value);
              ref.invalidate(localBaseUrlProvider);
            },
          ),
          ListTile(
            leading: const Icon(Icons.visibility_outlined),
            title: const Text('Vision model name'),
            subtitle: Text(model),
            onTap: () async {
              final value = await _editText(context, 'Model name', model,
                  hint: 'qwen2.5-vl, llava, minicpm-v, ...');
              if (value == null) return;
              await ref.read(settingsRepositoryProvider).setLocalModel(value);
              ref.invalidate(localModelProvider);
            },
          ),
          const _LocalApiKeyTile(
              subtitle: 'Only if that server requires one. Sent as a bearer '
                  'token with the image request.'),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
                'Must be a multimodal model (Qwen2.5-VL, LLaVA, MiniCPM-V, '
                'Gemma 3 4B+) and reachable from the phone - a text-only one '
                'rejects the whole request. These are the same settings as '
                'the Local server provider.',
                style: TextStyle(color: Colors.grey)),
          ),
        ],
      ],
    );
  }
}

class _LocalSection extends ConsumerWidget {
  const _LocalSection({
    required this.baseUrl,
    required this.model,
    required this.vision,
    required this.contextTokens,
  });

  final String baseUrl;
  final String model;
  final bool vision;
  final int contextTokens;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Header('Local server settings'),
        ListTile(
          leading: const Icon(Icons.dns_outlined),
          title: const Text('Server URL'),
          subtitle: Text(baseUrl),
          onTap: () async {
            final value = await _editText(context, 'Server URL', baseUrl,
                hint: 'http://10.0.2.2:11434');
            if (value == null) return;
            await ref.read(settingsRepositoryProvider).setLocalBaseUrl(value);
            ref.invalidate(localBaseUrlProvider);
          },
        ),
        ListTile(
          leading: const Icon(Icons.psychology_outlined),
          title: const Text('Model name'),
          subtitle: Text(model),
          onTap: () async {
            final value = await _editText(context, 'Model name', model,
                hint: 'llama3.1, qwen2.5, ...');
            if (value == null) return;
            await ref.read(settingsRepositoryProvider).setLocalModel(value);
            ref.invalidate(localModelProvider);
          },
        ),
        const _LocalApiKeyTile(
            subtitle: 'Ollama and llama.cpp need none. Set one for LM Studio '
                'with auth on, an OpenAI-compatible gateway, or a tunnel that '
                'guards the endpoint.'),
        ListTile(
          leading: const Icon(Icons.straighten),
          title: const Text('Context size'),
          subtitle: Text('$contextTokens tokens - must match the '
              '--ctx-size your server was started with. Exa budgets what it '
              'sends against this; set it too high and the server rejects '
              'requests outright.'),
          isThreeLine: true,
          onTap: () async {
            final value = await _editText(
                context, 'Context size (tokens)', '$contextTokens',
                hint: '32768');
            if (value == null) return;
            final tokens = int.tryParse(value.trim());
            if (tokens == null) return;
            await ref
                .read(settingsRepositoryProvider)
                .setLocalContextTokens(tokens);
            ref.invalidate(localContextProvider);
          },
        ),
        SwitchListTile(
          secondary: const Icon(Icons.image_outlined),
          value: vision,
          title: const Text('Model can see images'),
          subtitle: const Text(
              'Turn on only for a multimodal model (Qwen2.5-VL, LLaVA, '
              'MiniCPM-V, Gemma 3 4B+). Screenshots and image attachments '
              'are then sent to the server instead of the cloud. A text-only '
              'model will reject them.'),
          onChanged: (value) async {
            await ref.read(settingsRepositoryProvider).setLocalVision(value);
            ref.invalidate(localVisionProvider);
          },
        ),
        ListTile(
          leading: const Icon(Icons.wifi_tethering),
          title: const Text('Test connection'),
          subtitle: const Text('Check the server is reachable'),
          onTap: () => _testConnection(context, ref),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Text(
              'Tip: from the Android emulator, a server on your computer is '
              'reachable at 10.0.2.2. On a physical device, use the '
              "computer's LAN IP and make sure the server listens on 0.0.0.0.",
              style: TextStyle(color: Colors.grey)),
        ),
      ],
    );
  }

  Future<void> _testConnection(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final trimmed =
        baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    // Same credential a real turn sends, so a guarded endpoint is tested as
    // the app will actually reach it rather than reported as a bare 401.
    final key = await ref.read(settingsRepositoryProvider).getLocalApiKey();
    try {
      final response = await http.get(
        Uri.parse('$trimmed/v1/models'),
        headers: {
          if (key != null && key.isNotEmpty) 'authorization': 'Bearer $key',
        },
      ).timeout(const Duration(seconds: 10));
      final ok = response.statusCode == 200;
      String detail = '';
      if (ok) {
        try {
          final body = (jsonDecode(response.body) as Map)['data'] as List?;
          detail = body == null ? '' : ' (${body.length} models)';
        } catch (_) {}
      }
      final unauthorized =
          response.statusCode == 401 || response.statusCode == 403;
      messenger.showSnackBar(SnackBar(
          content: Text(ok
              ? 'Connected to the local server$detail.'
              : unauthorized
                  ? 'Server rejected the credentials (HTTP '
                      '${response.statusCode}). Check the API key.'
                  : 'Server responded with HTTP ${response.statusCode}.')));
    } catch (e) {
      messenger.showSnackBar(
          SnackBar(content: Text('Could not reach $trimmed: $e')));
    }
  }
}

/// The local server's bearer token. Shown in both the Local server section and
/// the DeepSeek images section, because one server answers both and one stored
/// key serves them - the alternative is switching provider to configure it and
/// switching back.
class _LocalApiKeyTile extends ConsumerWidget {
  const _LocalApiKeyTile({required this.subtitle});

  final String subtitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasKey = ref.watch(hasLocalKeyProvider).value ?? false;
    return ListTile(
      leading: Icon(hasKey ? Icons.key : Icons.key_off,
          color: hasKey ? Colors.green : null),
      title: Text(hasKey ? 'API key saved' : 'No API key (optional)'),
      subtitle: Text(subtitle),
      isThreeLine: true,
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        final value = await _editText(context, 'Local server API key', '',
            hint: 'Leave empty for no key',
            obscure: true,
            allowEmpty: true);
        if (value == null) return;
        await ref
            .read(settingsRepositoryProvider)
            .setLocalApiKey(value.isEmpty ? null : value);
        ref.invalidate(hasLocalKeyProvider);
      },
    );
  }
}

class _OnDeviceSection extends ConsumerWidget {
  const _OnDeviceSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(onDeviceModelsControllerProvider);
    final controller = ref.read(onDeviceModelsControllerProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Header('HuggingFace token'),
        ListTile(
          leading: Icon(state.hasToken ? Icons.vpn_key : Icons.vpn_key_outlined,
              color: state.hasToken ? Colors.green : null),
          title: Text(state.hasToken ? 'Token saved' : 'No token set'),
          subtitle: const Text(
              'Only needed for gated models (Gemma). Create a free read token '
              'at huggingface.co/settings/tokens.'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async {
            final value = await _editText(context, 'HuggingFace token', '',
                hint: 'hf_...', obscure: true, allowEmpty: true);
            if (value == null) return;
            await controller.setToken(value.isEmpty ? null : value);
          },
        ),
        if (state.hasToken)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: TextButton.icon(
              onPressed: () => controller.setToken(null),
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Remove token'),
            ),
          ),
        const Divider(),
        const _Header('Downloadable models'),
        if (state.loading)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: LinearProgressIndicator(),
          )
        else
          for (final model in kOnDeviceCatalog)
            _CatalogTile(
              model: model,
              state: state.stateFor(model.id),
              active: state.activeId == model.id,
              controller: controller,
            ),
        const Divider(),
        _FileInstallTile(state: state, controller: controller),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Text(
              'On-device AI is experimental: it runs entirely offline but '
              'cannot use tools (create tasks, build screens), cannot read '
              'images or PDFs, and is not used for scheduled background '
              'briefings. Model files are large - use Wi-Fi, and keep the app '
              'open until a download finishes.',
              style: TextStyle(color: Colors.grey)),
        ),
      ],
    );
  }
}

/// One downloadable catalog model, with a control that reflects its state:
/// download / progress+cancel / active / installed-inactive.
class _CatalogTile extends StatelessWidget {
  const _CatalogTile({
    required this.model,
    required this.state,
    required this.active,
    required this.controller,
  });

  final OnDeviceModel model;
  final OnDeviceModelState state;
  final bool active;
  final OnDeviceModelsController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                  child: Text(model.name,
                      style: theme.textTheme.titleMedium)),
              if (active) const _ActiveChip(),
            ],
          ),
          const SizedBox(height: 2),
          Text(model.tagline, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _Tag(model.sizeLabel, icon: Icons.sd_storage_outlined),
              if (model.gated) const _Tag('Needs token', icon: Icons.lock_outline),
            ],
          ),
          if (model.note != null) ...[
            const SizedBox(height: 4),
            Text(model.note!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: Colors.grey)),
          ],
          const SizedBox(height: 8),
          _control(context),
          if (state.status == OnDeviceStatus.failed && state.error != null) ...[
            const SizedBox(height: 6),
            Text(state.error!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error)),
          ],
        ],
      ),
    );
  }

  Widget _control(BuildContext context) {
    switch (state.status) {
      case OnDeviceStatus.downloading:
        final value = state.progress > 0 ? state.progress / 100 : null;
        return Row(
          children: [
            Expanded(child: LinearProgressIndicator(value: value)),
            const SizedBox(width: 12),
            SizedBox(
                width: 40,
                child: Text('${state.progress}%',
                    textAlign: TextAlign.right)),
            IconButton(
              tooltip: 'Cancel',
              icon: const Icon(Icons.close),
              onPressed: () => controller.cancelDownload(model.id),
            ),
          ],
        );
      case OnDeviceStatus.installed:
        return Row(
          children: [
            if (!active)
              FilledButton.tonal(
                onPressed: () => controller.activate(model),
                child: const Text('Use this model'),
              ),
            if (!active) const SizedBox(width: 8),
            TextButton.icon(
              onPressed: () => _confirmDelete(context),
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Delete'),
            ),
          ],
        );
      case OnDeviceStatus.notInstalled:
      case OnDeviceStatus.failed:
        final retry = state.status == OnDeviceStatus.failed;
        return FilledButton.icon(
          onPressed: () => controller.download(model),
          icon: Icon(retry ? Icons.refresh : Icons.download_outlined, size: 18),
          label: Text(retry ? 'Retry download' : 'Download'),
        );
    }
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete ${model.name}?'),
        content: Text('This frees ${model.sizeLabel} of storage. You can '
            'download it again later.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) await controller.delete(model);
  }
}

/// The "install from file" fallback, plus status of any sideloaded model.
class _FileInstallTile extends StatelessWidget {
  const _FileInstallTile({required this.state, required this.controller});

  final OnDeviceModelsState state;
  final OnDeviceModelsController controller;

  @override
  Widget build(BuildContext context) {
    final active = state.activeId == kSideloadId;
    final hasFile = state.filePath != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: const Icon(Icons.folder_open_outlined),
          title: Row(
            children: [
              const Flexible(child: Text('Install from file')),
              if (active) ...[const SizedBox(width: 8), const _ActiveChip()],
            ],
          ),
          subtitle: Text(hasFile
              ? 'A sideloaded .task model is installed.'
              : 'Advanced: pick a MediaPipe .task model already on this device.'),
          trailing: state.fileBusy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.chevron_right),
          onTap: state.fileBusy
              ? null
              : () async {
                  final picked =
                      await FilePicker.pickFiles(type: FileType.any);
                  final path = picked?.files.single.path;
                  if (path == null) return;
                  await controller.installFromFile(path);
                },
        ),
        if (state.fileError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(state.fileError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
      ],
    );
  }
}

class _ActiveChip extends StatelessWidget {
  const _ActiveChip();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle, size: 14, color: scheme.onPrimaryContainer),
          const SizedBox(width: 4),
          Text('Active',
              style: TextStyle(
                  fontSize: 12, color: scheme.onPrimaryContainer)),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.label, {this.icon});
  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: scheme.onSurfaceVariant),
            const SizedBox(width: 4),
          ],
          Text(label,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall),
      );
}

/// Small single-field edit dialog returning the trimmed value, or null on
/// cancel. When [allowEmpty] is true an empty result is returned as '' (used to
/// clear a value); otherwise empty is treated as cancel.
Future<String?> _editText(BuildContext context, String title, String initial,
    {String? hint, bool obscure = false, bool allowEmpty = false}) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        obscureText: obscure,
        decoration: InputDecoration(
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Save')),
      ],
    ),
  );
  if (result == null) return null;
  if (result.isEmpty && !allowEmpty) return null;
  return result;
}
