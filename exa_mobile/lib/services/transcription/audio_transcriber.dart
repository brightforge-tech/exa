import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../data/models/inbound_media.dart';
import '../../data/repositories/settings_repository.dart';
import '../files/file_service.dart';

/// ---------------------------------------------------------------------------
/// File-audio transcription.
///
/// One outcome vocabulary for every way a transcription can end, so callers
/// branch on a status instead of catching exceptions that might have carried
/// audio content in their message.
enum TranscriptionStatus {
  /// Words were heard. [TranscriptionResult.text] carries them.
  done,

  /// The call succeeded and the audio holds nothing - silence, or a few
  /// mouth-noise seconds. Terminal: re-transcribing the same bytes gives the
  /// same nothing, so no retry is owed.
  empty,

  /// The endpoint was reachable-but-unwell, or unreachable at all: timeout,
  /// 429, 5xx, a dropped socket. Retryable, within the caller's attempt cap
  /// and circuit breaker.
  failed,

  /// This audio cannot be transcribed here no matter how often we ask: the
  /// file is missing, empty or over the size ceiling, or the endpoint says it
  /// does not accept it (4xx other than 408/429). Terminal.
  unsupported,

  /// Nothing to talk to - no local AI server is configured. A caller skips
  /// the whole pass rather than recording a failure per row, and tries again
  /// once the user has set the endpoint.
  unavailable,
}

/// The typed answer to one transcription attempt.
///
/// [detail] is display-safe by construction: it names only the failure class
/// (an HTTP status or an exception type), never transcript text, never audio
/// bytes, never a signed URL. It is written to job reports and diagnostics
/// the model reads, so anything it echoed would be outside content the model
/// can see. Callers branch on [status]; [detail] is for the human line that
/// explains it.
class TranscriptionResult {
  const TranscriptionResult({required this.status, this.text, this.detail});

  final TranscriptionStatus status;

  /// The words heard, or null unless [status] is [TranscriptionStatus.done].
  final String? text;

  /// Human-readable reason for a non-`done` status; display-safe (see the
  /// class comment).
  final String? detail;

  bool get hasText => text != null && text!.trim().isNotEmpty;
}

/// Turns an audio file - bytes the caller already has, or a path to one -
/// into text.
///
/// Deliberately not an `AiClient`: the Anthropic block format has no audio
/// shape any backend here can receive, and the OpenAI-compatible translator
/// forwards only tool_result / text / image blocks, so an audio block handed
/// to it would be dropped silently and the model would answer as though the
/// voice note had been only its note text. Transcription therefore lives on
/// its own one-endpoint wire, and no audio bytes ever enter a chat request.
abstract class AudioTranscriber {
  /// Ceiling on the transcript a caller may keep, in characters.
  ///
  /// A voice note's worth of speech is a few thousand characters at most;
  /// anything past this is a provider looping or emitting noise, and it would
  /// crowd out the rest of a budgeted digest turn. Longer answers arrive
  /// truncated with a trailing marker so the reader can tell.
  static const maxTranscriptChars = 12000;

  /// Whether there is an endpoint to talk to, read from the stored settings
  /// at the moment of the question - every call, not from a cache.
  ///
  /// Asynchronously read on purpose. The answer lives in the database, and
  /// the callers that ask are background job runs that construct their own
  /// transcriber moments before asking; a synchronous getter would have to
  /// answer from a cache those callers never warmed, and every pass would
  /// silently skip - no voice note ever transcribed. One settings query is
  /// negligible next to the pass it gates.
  Future<bool> get isConfigured;

  /// Transcribe the audio file at [path].
  ///
  /// The only checks on the path are that the file exists, is not empty and
  /// is within [FileService.maxMediaAudioBytes] - all answered before any
  /// bytes are read. This class owns no path-provenance rule and is given no
  /// media directory: proving a path belongs to media capture is the caller's
  /// job (the captured-media caller verifies the sidecar with
  /// `MessageSpoolReader.sidecarOk` first; a chat attachment never uses this
  /// method at all, because its bytes are already in memory).
  Future<TranscriptionResult> transcribeFile(
    String path, {
    String? mimeType,
    Duration? timeout,
  });

  /// Transcribe audio already held in memory, named by [fileName] (used for
  /// the multipart filename the provider sees, and for the gate messages).
  Future<TranscriptionResult> transcribeBytes(
    Uint8List bytes, {
    required String fileName,
    String? mimeType,
    Duration? timeout,
  });
}

/// ---------------------------------------------------------------------------
/// The OpenAI-compatible implementation: one multipart POST to
/// `<local endpoint>/v1/audio/transcriptions` on the local AI server the user
/// set up in Settings > AI provider.
///
/// Two choices deserve their reasons spelled out.
///
/// *Config.* The endpoint and its key are read from [SettingsRepository] at
/// call time (the way `LocalEndpointClient` is re-pointed each turn), and the
/// base URL is taken from the *stored* setting only - never from
/// [SettingsRepository.defaultLocalBaseUrl]. The default exists so a chat
/// provider the user explicitly picked has a starting address; blasting a
/// stranger's voice audio at an address the user never chose - an emulator
/// default that resolves to nothing, or worse, to something else, on a real
/// phone - would be a privacy failure no chat bug shares. No URL stored means
/// no transcription, and `transcribe` answers `unavailable` with zero
/// network calls.
///
/// *Fields.* The request carries the file and `response_format=json` and
/// nothing else: no `model` (the operator's standing rule - the local server
/// answers with whatever it has loaded), and no `language` (the provider
/// auto-detects, and guessing wrong forces a bad transcript instead of
/// letting the provider hear the difference).
///
/// Like the interface, this class knows nothing about where a file came from:
/// it is handed paths and bytes, never a media directory, and owns no naming
/// or provenance check of its own.
class OpenAiAudioTranscriber implements AudioTranscriber {
  OpenAiAudioTranscriber({
    required this.settings,
    http.Client? httpClient,
    this.requestTimeout = const Duration(seconds: 60),
  }) : _http = httpClient ?? http.Client();

  final SettingsRepository settings;

  /// Injected in tests (a `MockClient`); production takes the default. When
  /// one is passed in, the caller keeps ownership of closing it.
  final http.Client _http;

  /// Per-call ceiling. Generous by default: a whisper run on modest hardware
  /// legitimately grinds, and giving up early reports dead what was merely
  /// slow. A caller may shorten it per call to fit a time slice.
  final Duration requestTimeout;

  /// Whether the user has pointed the app at a local AI server, read from
  /// the settings at the moment of the question - see [AudioTranscriber.isConfigured]
  /// for why this cannot be a cached sync bool.
  @override
  Future<bool> get isConfigured async =>
      (await _readStoredBaseUrl())?.trim().isNotEmpty ?? false;

  /// The *stored* base URL, or null when the user never set one. Never
  /// [SettingsRepository.defaultLocalBaseUrl]: this app's rule (see the
  /// class comment) is that audio only travels to an address the user chose,
  /// so "no stored URL" means "no transcription", not "use the default".
  Future<String?> _readStoredBaseUrl() =>
      settings.getValue(SettingsRepository.aiLocalBaseUrlKey);

  @override
  Future<TranscriptionResult> transcribeFile(
    String path, {
    String? mimeType,
    Duration? timeout,
  }) async {
    final baseUrl = (await _readStoredBaseUrl())?.trim() ?? '';
    if (baseUrl.isEmpty) return _unconfigured;
    final name = p.basename(path);
    // Every gate below answers from a stat, never a read - a rejected file
    // must not cost its bytes in memory or a request.
    final file = File(path);
    if (!await file.exists()) {
      return TranscriptionResult(
        status: TranscriptionStatus.unsupported,
        detail: 'Audio file is missing: $name',
      );
    }
    final int sizeBytes;
    try {
      sizeBytes = await file.length();
    } on FileSystemException {
      // Gone between the check and the stat, or unreadable - same answer,
      // and `unsupported` matches what a caller will do with it.
      return TranscriptionResult(
        status: TranscriptionStatus.unsupported,
        detail: 'Audio file is missing: $name',
      );
    }
    final gate = _sizeGate(name, sizeBytes);
    if (gate != null) {
      return TranscriptionResult(status: TranscriptionStatus.unsupported, detail: gate);
    }
    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } on FileSystemException {
      return TranscriptionResult(
        status: TranscriptionStatus.unsupported,
        detail: 'Audio file is missing: $name',
      );
    }
    return _transcribe(bytes, name, timeout ?? requestTimeout, baseUrl);
  }

  @override
  Future<TranscriptionResult> transcribeBytes(
    Uint8List bytes, {
    required String fileName,
    String? mimeType,
    Duration? timeout,
  }) async {
    final baseUrl = (await _readStoredBaseUrl())?.trim() ?? '';
    if (baseUrl.isEmpty) return _unconfigured;
    final name = p.basename(fileName);
    final gate = _sizeGate(name, bytes.lengthInBytes);
    if (gate != null) {
      return TranscriptionResult(status: TranscriptionStatus.unsupported, detail: gate);
    }
    return _transcribe(bytes, name, timeout ?? requestTimeout, baseUrl);
  }

  // ------------------------------------------------------------- the request

  static const _unconfigured = TranscriptionResult(
    status: TranscriptionStatus.unavailable,
    detail: 'No local AI server is configured. Set its address in '
        'Settings > AI provider to transcribe voice notes.',
  );

  /// The one media-size gate this class owns, shared by both entry points.
  /// null means "acceptable"; anything else is the display-safe reason.
  static String? _sizeGate(String name, int sizeBytes) {
    if (sizeBytes == 0) {
      return 'Audio file is empty: $name';
    }
    if (sizeBytes > FileService.maxMediaAudioBytes) {
      return 'Audio file is too large '
          '(${InboundMedia.formatBytes(sizeBytes)}; limit '
          '${InboundMedia.formatBytes(FileService.maxMediaAudioBytes)}): '
          '$name';
    }
    return null;
  }

  /// Send the multipart request and interpret the answer.
  ///
  /// The timeout covers the whole exchange - connect, upload, wait, body -
  /// because an endpoint that accepts the socket and then says nothing is
  /// exactly the failure this path must not hang a budgeted job on.
  ///
  /// [mimeType] is part of the interface for callers that know it; this wire
  /// does not use it - the part travels as octet-stream and whisper servers
  /// sniff the container from the filename and the bytes, so adding a
  /// per-part type could only add a way to be wrong.
  Future<TranscriptionResult> _transcribe(
    Uint8List bytes,
    String name,
    Duration timeout,
    String baseUrl,
  ) async {
    final endpoint = _endpoint(baseUrl);
    final Uri url;
    try {
      url = Uri.parse(endpoint);
    } on FormatException {
      return _invalidUrl;
    }
    if (url.scheme != 'http' && url.scheme != 'https') return _invalidUrl;

    final request = http.MultipartRequest('POST', url)
      ..fields['response_format'] = 'json';
    // Quotes and line breaks would corrupt the multipart framing itself; no
    // provider needs a filename that cannot be carried inside the header.
    final safeName = name.replaceAll(RegExp(r'["\r\n]'), '_');
    request.files.add(
      http.MultipartFile.fromBytes('file', bytes, filename: safeName),
    );
    final key = await _readApiKey();
    if (key != null && key.trim().isNotEmpty) {
      request.headers['authorization'] = 'Bearer ${key.trim()}';
    }

    final http.Response response;
    try {
      response = await _send(request).timeout(timeout);
    } on TimeoutException {
      final span = timeout.inSeconds > 0
          ? '${timeout.inSeconds}s'
          : '${timeout.inMilliseconds}ms';
      return TranscriptionResult(
        status: TranscriptionStatus.failed,
        detail: 'Transcription timed out after $span',
      );
    } on http.ClientException catch (e) {
      return TranscriptionResult(
        status: TranscriptionStatus.failed,
        detail: 'Could not reach the transcription endpoint '
            '(${e.runtimeType})',
      );
    } catch (e) {
      // Runtime type only: an OS-level message can name a socket, a path,
      // or a URL, and this string is written where the model can read it.
      return TranscriptionResult(
        status: TranscriptionStatus.failed,
        detail: 'Transcription failed (${e.runtimeType})',
      );
    }
    return _interpret(response);
  }

  /// The full exchange, as one future, so a single `.timeout` bounds it.
  Future<http.Response> _send(http.MultipartRequest request) async {
    final streamed = await _http.send(request);
    return http.Response.fromStream(streamed);
  }

  /// `<stored base URL>/v1/audio/transcriptions`, one trailing slash trimmed.
  static String _endpoint(String baseUrl) {
    var base = baseUrl;
    if (base.endsWith('/')) base = base.substring(0, base.length - 1);
    return '$base/v1/audio/transcriptions';
  }

  static const _invalidUrl = TranscriptionResult(
    status: TranscriptionStatus.failed,
    detail: 'The configured transcription URL is not a valid http(s) address.',
  );

  /// The local endpoint's key, or null when none is stored. A secure-store
  /// that cannot answer is treated as "no key", not as a transcription
  /// failure: plenty of local servers want no header at all, and a credential
  /// read must not be what stops a voice note becoming text.
  Future<String?> _readApiKey() async {
    try {
      return await settings.getLocalApiKey();
    } catch (_) {
      return null;
    }
  }

  // -------------------------------------------------------- answer -> status

  /// Map the HTTP answer onto the status vocabulary.
  ///
  /// 4xx (other than 408/429) is `unsupported`: the endpoint is healthy and
  /// is saying *this audio, not here*, which no retry changes. 408/429/5xx
  /// are `failed`: the endpoint itself was in the way, which is retryable.
  /// `detail` is built from the status code alone - the response body is
  /// never quoted, because provider error bodies echo request echoes, model
  /// names, and signed URLs alike.
  TranscriptionResult _interpret(http.Response response) {
    final status = response.statusCode;
    if (status == 200) {
      final Object? decoded;
      try {
        decoded = jsonDecode(response.body);
      } on FormatException {
        return const TranscriptionResult(
          status: TranscriptionStatus.failed,
          detail: 'The transcription endpoint answered with something '
              'that is not JSON.',
        );
      }
      final raw = decoded is Map ? decoded['text'] : null;
      final text = raw is String ? raw : null;
      if (text == null || text.trim().isEmpty) {
        return const TranscriptionResult(
          status: TranscriptionStatus.empty,
          detail: 'The transcription endpoint heard no words.',
        );
      }
      return TranscriptionResult(
        status: TranscriptionStatus.done,
        text: _cap(text),
      );
    }
    switch (status) {
      case 408:
        return TranscriptionResult(
          status: TranscriptionStatus.failed,
          detail: 'The transcription endpoint timed out (HTTP $status)',
        );
      case 429:
        return TranscriptionResult(
          status: TranscriptionStatus.failed,
          detail: 'The transcription endpoint is busy (HTTP $status)',
        );
      default:
        if (status >= 500) {
          return TranscriptionResult(
            status: TranscriptionStatus.failed,
            detail: 'The transcription endpoint failed (HTTP $status)',
          );
        }
        return TranscriptionResult(
          status: TranscriptionStatus.unsupported,
          detail: 'The transcription endpoint rejected this audio '
              '(HTTP $status)',
        );
    }
  }

  /// Hard cap with a visible marker: keepers see that the tail is gone
  /// rather than reading a clean-looking ending that was really a cut. The
  /// marker is inside [AudioTranscriber.maxTranscriptChars], not appended
  /// past it, so a caller can size its budgets on the constant.
  static String _cap(String text) {
    const marker = '[truncated]';
    if (text.length <= AudioTranscriber.maxTranscriptChars) return text;
    final keep =
        AudioTranscriber.maxTranscriptChars - marker.length - 1; // the space
    return '${text.substring(0, keep)} $marker';
  }
}
