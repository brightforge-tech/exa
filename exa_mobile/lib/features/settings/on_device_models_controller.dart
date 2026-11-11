import 'dart:io' show File, Platform;

import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/settings_repository.dart';
import '../../services/ai_client/on_device_catalog.dart';
import '../../services/ai_client/on_device_runtime.dart';
import '../../shared/providers.dart';

/// Sentinel [OnDeviceModelsState.activeId] value meaning "a user-sideloaded
/// file model is the active one" (as opposed to a catalog entry).
const String kSideloadId = '__file__';

enum OnDeviceStatus { notInstalled, downloading, installed, failed }

/// Per-catalog-model view state.
class OnDeviceModelState {
  const OnDeviceModelState({
    this.status = OnDeviceStatus.notInstalled,
    this.progress = 0,
    this.error,
  });

  final OnDeviceStatus status;

  /// Download progress 0-100 while [status] is [OnDeviceStatus.downloading].
  final int progress;
  final String? error;

  OnDeviceModelState copyWith({
    OnDeviceStatus? status,
    int? progress,
    String? error,
    bool clearError = false,
  }) =>
      OnDeviceModelState(
        status: status ?? this.status,
        progress: progress ?? this.progress,
        error: clearError ? null : (error ?? this.error),
      );
}

/// Whole-screen state for the on-device model manager.
class OnDeviceModelsState {
  const OnDeviceModelsState({
    this.loading = true,
    this.byId = const {},
    this.activeId,
    this.filePath,
    this.fileBusy = false,
    this.fileError,
    this.hasToken = false,
  });

  final bool loading;
  final Map<String, OnDeviceModelState> byId;

  /// Active model: a catalog [OnDeviceModel.id], [kSideloadId] for a sideloaded
  /// file, or null when nothing is active.
  final String? activeId;

  /// Path of a sideloaded file model, if one is installed.
  final String? filePath;
  final bool fileBusy;
  final String? fileError;

  /// Whether a HuggingFace token is stored (needed for gated models).
  final bool hasToken;

  OnDeviceModelState stateFor(String id) =>
      byId[id] ?? const OnDeviceModelState();

  OnDeviceModelsState copyWith({
    bool? loading,
    Map<String, OnDeviceModelState>? byId,
    String? activeId,
    bool clearActiveId = false,
    String? filePath,
    bool clearFilePath = false,
    bool? fileBusy,
    String? fileError,
    bool clearFileError = false,
    bool? hasToken,
  }) =>
      OnDeviceModelsState(
        loading: loading ?? this.loading,
        byId: byId ?? this.byId,
        activeId: clearActiveId ? null : (activeId ?? this.activeId),
        filePath: clearFilePath ? null : (filePath ?? this.filePath),
        fileBusy: fileBusy ?? this.fileBusy,
        fileError: clearFileError ? null : (fileError ?? this.fileError),
        hasToken: hasToken ?? this.hasToken,
      );
}

/// Owns the lifecycle of on-device models: which are installed, download
/// progress, the active selection, and the HuggingFace token. This is the
/// single source of truth for the On-device section of the AI provider screen.
class OnDeviceModelsController extends StateNotifier<OnDeviceModelsState> {
  OnDeviceModelsController(this._settings)
      : super(const OnDeviceModelsState()) {
    _load();
  }

  final SettingsRepository _settings;
  final Map<String, CancelToken> _cancelTokens = {};

  Future<void> _load() async {
    // The On-device settings section is the other place the plugin is first
    // touched, so it initializes here too (see [OnDeviceRuntime]).
    await OnDeviceRuntime.ensureInitialized();
    final byId = <String, OnDeviceModelState>{};
    for (final model in kOnDeviceCatalog) {
      bool installed = false;
      try {
        installed = await FlutterGemma.isModelInstalled(model.filename);
      } catch (_) {
        // Plugin unavailable on this platform/build - treat as not installed.
      }
      byId[model.id] = OnDeviceModelState(
        status: installed
            ? OnDeviceStatus.installed
            : OnDeviceStatus.notInstalled,
      );
    }

    final storedId = await _settings.getOnDeviceModelId();
    final storedPath = await _settings.getOnDeviceModelPath();
    final token = await _settings.getHuggingFaceToken();
    final fileExists =
        storedPath != null && storedPath.isNotEmpty && File(storedPath).existsSync();

    String? activeId;
    if (storedId != null && byId[storedId]?.status == OnDeviceStatus.installed) {
      activeId = storedId;
    } else if (fileExists) {
      activeId = kSideloadId;
    }

    if (!mounted) return;
    state = state.copyWith(
      loading: false,
      byId: byId,
      activeId: activeId,
      clearActiveId: activeId == null,
      filePath: fileExists ? storedPath : null,
      clearFilePath: !fileExists,
      hasToken: token != null && token.isNotEmpty,
    );
  }

  /// Downloads a catalog model and sets it active. Progress streams into state.
  Future<void> download(OnDeviceModel model) async {
    if (!Platform.isAndroid) {
      _setModel(
          model.id,
          const OnDeviceModelState(
              status: OnDeviceStatus.failed,
              error: 'On-device models run on Android only.'));
      return;
    }

    final token = await _settings.getHuggingFaceToken();
    if (model.gated && (token == null || token.isEmpty)) {
      _setModel(
          model.id,
          const OnDeviceModelState(
              status: OnDeviceStatus.failed,
              error: 'This model is gated. Add a HuggingFace token above, '
                  'then tap Download again.'));
      return;
    }

    final cancelToken = CancelToken();
    _cancelTokens[model.id] = cancelToken;
    _setModel(model.id,
        const OnDeviceModelState(status: OnDeviceStatus.downloading));

    try {
      await FlutterGemma.installModel(
              modelType: model.modelType, fileType: model.fileType)
          .fromNetwork(model.url, token: token)
          .withProgress((p) {
        final current = state.stateFor(model.id);
        if (current.status == OnDeviceStatus.downloading) {
          _setModel(model.id, current.copyWith(progress: p.clamp(0, 100)));
        }
      }).withCancelToken(cancelToken).install();

      await _persistActive(model.id);
      _setModel(
          model.id, const OnDeviceModelState(status: OnDeviceStatus.installed));
      if (mounted) {
        state = state.copyWith(activeId: model.id, clearFilePath: true);
      }
    } catch (e) {
      if (CancelToken.isCancel(e)) {
        _setModel(model.id,
            const OnDeviceModelState(status: OnDeviceStatus.notInstalled));
      } else {
        _setModel(
            model.id,
            OnDeviceModelState(
                status: OnDeviceStatus.failed,
                error: _friendlyDownloadError(e, model)));
      }
    } finally {
      _cancelTokens.remove(model.id);
    }
  }

  void cancelDownload(String id) =>
      _cancelTokens[id]?.cancel('Cancelled by user');

  /// Makes an already-installed catalog model the active one. `install()` is
  /// idempotent, so this re-sets the active pointer without re-downloading.
  Future<void> activate(OnDeviceModel model) async {
    try {
      await FlutterGemma.installModel(
              modelType: model.modelType, fileType: model.fileType)
          .fromNetwork(model.url)
          .install();
      await _persistActive(model.id);
      if (mounted) {
        state = state.copyWith(activeId: model.id, clearFilePath: true);
      }
    } catch (e) {
      _setModel(
          model.id,
          state.stateFor(model.id).copyWith(
              status: OnDeviceStatus.failed, error: 'Could not activate: $e'));
    }
  }

  /// Deletes a downloaded catalog model from device storage.
  Future<void> delete(OnDeviceModel model) async {
    try {
      await FlutterGemma.uninstallModel(model.filename);
    } catch (_) {
      // Best effort - fall through and reflect not-installed either way.
    }
    final wasActive = state.activeId == model.id;
    if (wasActive) await _settings.setOnDeviceModelId(null);
    _setModel(
        model.id, const OnDeviceModelState(status: OnDeviceStatus.notInstalled));
    if (wasActive && mounted) state = state.copyWith(clearActiveId: true);
  }

  /// Installs a model from a user-picked `.task` file and sets it active.
  Future<void> installFromFile(String path) async {
    if (mounted) state = state.copyWith(fileBusy: true, clearFileError: true);
    try {
      await FlutterGemma.installModel(modelType: ModelType.gemmaIt)
          .fromFile(path)
          .install();
      await _settings.setOnDeviceModelPath(path);
      await _settings.setOnDeviceModelId(null);
      if (mounted) {
        state = state.copyWith(
            fileBusy: false, filePath: path, activeId: kSideloadId);
      }
    } catch (e) {
      if (mounted) {
        state = state.copyWith(fileBusy: false, fileError: 'Install failed: $e');
      }
    }
  }

  Future<void> setToken(String? token) async {
    await _settings.setHuggingFaceToken(token);
    if (mounted) {
      state = state.copyWith(hasToken: token != null && token.isNotEmpty);
    }
  }

  Future<void> _persistActive(String id) async {
    await _settings.setOnDeviceModelId(id);
    await _settings.setOnDeviceModelPath(null);
  }

  void _setModel(String id, OnDeviceModelState modelState) {
    if (!mounted) return;
    final next = Map<String, OnDeviceModelState>.from(state.byId);
    next[id] = modelState;
    state = state.copyWith(byId: next);
  }

  String _friendlyDownloadError(Object e, OnDeviceModel model) {
    final s = e.toString();
    if (s.contains('401') || s.contains('Unauthorized')) {
      return model.gated
          ? 'HuggingFace rejected the download (401). Check your token above, '
              'and accept the license on the model page.'
          : 'HuggingFace rejected the download (401). Adding a token above may '
              'help.';
    }
    if (s.contains('403') || s.contains('Forbidden')) {
      return 'Access forbidden (403). Open the model page on HuggingFace and '
          'accept its license, then retry.';
    }
    if (s.contains('404')) {
      return 'Model file not found (404). The download URL may have changed.';
    }
    return 'Download failed: $e';
  }
}

/// App-lifetime (not autoDispose) so a download keeps running when the user
/// navigates away from Settings; only an explicit Cancel stops it.
final onDeviceModelsControllerProvider =
    StateNotifierProvider<OnDeviceModelsController, OnDeviceModelsState>(
  (ref) => OnDeviceModelsController(ref.watch(settingsRepositoryProvider)),
);
