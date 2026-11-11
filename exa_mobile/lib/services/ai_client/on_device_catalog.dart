import 'package:flutter_gemma/flutter_gemma.dart' show ModelType, ModelFileType;

/// A curated, downloadable on-device model.
///
/// These are the same LiteRT / MediaPipe `.task` models that Google AI Edge
/// Gallery showcases, hosted on the HuggingFace `litert-community` / `google`
/// orgs. Everything here is a `.task` bundle (MediaPipe handles the chat
/// template internally), which is the format flutter_gemma loads most reliably.
class OnDeviceModel {
  const OnDeviceModel({
    required this.id,
    required this.name,
    required this.tagline,
    required this.url,
    required this.filename,
    required this.sizeBytes,
    required this.modelType,
    required this.maxTokens,
    this.fileType = ModelFileType.task,
    this.gated = false,
    this.note,
  });

  /// Stable identifier, persisted in settings to remember the active model.
  final String id;
  final String name;

  /// One-line description shown under the name.
  final String tagline;

  /// Direct HuggingFace download URL (must use the `/resolve/main/` form).
  final String url;

  /// Basename of [url]. flutter_gemma tracks installed models by this filename,
  /// so it must match exactly what the download produces.
  final String filename;

  final int sizeBytes;
  final ModelType modelType;

  /// Context window to request from MediaPipe. Must not exceed the model's
  /// built-in KV-cache size (baked into the `.task` file, e.g. the `ekv4096`
  /// in the filename) or model init fails.
  final int maxTokens;

  final ModelFileType fileType;

  /// Whether the HuggingFace repo requires an access token (gated model).
  final bool gated;

  /// Extra caveat surfaced in the UI (size, capabilities, etc.).
  final String? note;

  String get sizeLabel => formatBytes(sizeBytes);
}

/// Human-readable download size (decimal units, matching how stores show them).
String formatBytes(int bytes) {
  const gb = 1000 * 1000 * 1000;
  const mb = 1000 * 1000;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} GB';
  return '${(bytes / mb).round()} MB';
}

/// The models offered for one-tap download in Settings > AI provider.
///
/// Ordered easiest-first: Qwen needs no HuggingFace sign-in, the Gemma models
/// are gated and need a token (see [OnDeviceModel.gated]).
const List<OnDeviceModel> kOnDeviceCatalog = [
  OnDeviceModel(
    id: 'qwen2.5-1.5b-it',
    name: 'Qwen2.5 1.5B Instruct',
    tagline: 'Recommended. Solid all-rounder, no sign-in needed.',
    url: 'https://huggingface.co/litert-community/Qwen2.5-1.5B-Instruct/resolve/'
        'main/Qwen2.5-1.5B-Instruct_multi-prefill-seq_q8_ekv4096.task',
    filename: 'Qwen2.5-1.5B-Instruct_multi-prefill-seq_q8_ekv4096.task',
    sizeBytes: 1598556720,
    modelType: ModelType.qwen,
    maxTokens: 4096,
    note: '4K context, can use tools. Runs comfortably on ~4 GB+ of free RAM.',
  ),
  // Hammer 2.1 1.5B (a tool-calling-tuned model) is run via the Local server
  // provider using its ungated GGUF build, not on-device: the on-device .task
  // build (litert-community/Hammer2.1-1.5b) is gated and its filename can't be
  // verified. flutter_gemma still supports ModelType.hammer if a verified
  // .task/.litertlm becomes available.
  OnDeviceModel(
    id: 'gemma3-1b-it-int4',
    name: 'Gemma 3 1B (INT4)',
    tagline: 'Smallest and fastest. Needs a HuggingFace token.',
    url: 'https://huggingface.co/litert-community/Gemma3-1B-IT/resolve/main/'
        'gemma3-1b-it-int4.task',
    filename: 'gemma3-1b-it-int4.task',
    sizeBytes: 554661243,
    modelType: ModelType.gemmaIt,
    maxTokens: 1280,
    gated: true,
    note: 'Lightest option; good on lower-RAM devices. ~1.3K context.',
  ),
  OnDeviceModel(
    id: 'gemma-3n-e2b-it-int4',
    name: 'Gemma 3n E2B (INT4)',
    tagline: 'Largest and most capable. Needs a HuggingFace token + license.',
    url: 'https://huggingface.co/google/gemma-3n-E2B-it-litert-preview/resolve/'
        'main/gemma-3n-E2B-it-int4.task',
    filename: 'gemma-3n-E2B-it-int4.task',
    sizeBytes: 3136226711,
    modelType: ModelType.gemmaIt,
    maxTokens: 2048,
    gated: true,
    note: 'Multimodal model, but Exa uses it for text only. Wants ~6 GB+ RAM.',
  ),
];

/// Looks up a catalog entry by its stable [OnDeviceModel.id].
OnDeviceModel? onDeviceModelById(String? id) {
  if (id == null) return null;
  for (final model in kOnDeviceCatalog) {
    if (model.id == id) return model;
  }
  return null;
}
