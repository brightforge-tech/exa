import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/providers.dart';
import '../../shared/theme/exa_theme.dart';
import '../assistant/today_panel.dart';
import '../tasks/tasks_screen.dart';
import 'dictation_controller.dart';
import 'task_review_sheet.dart';
import 'transcript_analysis.dart';

/// A standalone live-transcription document. Press Record to dictate (the
/// recognizer runs continuously and appends, not replaces), edit the text by
/// hand, then Summarize it or pull the action items out of it as tasks, both
/// through the configured AI provider. Audio is never saved - only the
/// transcript text and an optional summary, which persist so the document can
/// be revisited and edited later.
class TranscribeEditorScreen extends ConsumerStatefulWidget {
  const TranscribeEditorScreen({super.key, this.transcriptId});

  /// Null for a new transcript; an existing id to load and edit.
  final String? transcriptId;

  @override
  ConsumerState<TranscribeEditorScreen> createState() =>
      _TranscribeEditorScreenState();
}

class _TranscribeEditorScreenState
    extends ConsumerState<TranscribeEditorScreen> {
  final _docController = TextEditingController();
  final _titleController = TextEditingController();

  /// Mutable so the first save of a new transcript switches us into
  /// update-in-place mode for subsequent saves.
  String? _transcriptId;
  String? _summary;
  bool _summarizing = false;
  bool _extracting = false;
  bool _saving = false;
  bool _loading = false;

  /// True while either AI action is in flight - both send the whole document,
  /// so running them at once just doubles the wait and the spend.
  bool get _busy => _summarizing || _extracting;

  @override
  void initState() {
    super.initState();
    _transcriptId = widget.transcriptId;
    if (_transcriptId != null) {
      _loading = true;
      _load(_transcriptId!);
    }
  }

  Future<void> _load(String id) async {
    final transcript = await ref.read(transcriptRepositoryProvider).get(id);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (transcript != null) {
        _titleController.text = transcript.title;
        _docController.text = transcript.content;
        _summary = transcript.summary;
      }
    });
    // Seed the dictation buffer so a first Record appends to existing text.
    ref
        .read(dictationControllerProvider.notifier)
        .setCommitted(_docController.text);
  }

  @override
  void dispose() {
    _docController.dispose();
    _titleController.dispose();
    super.dispose();
  }

  Future<void> _toggleMic() async {
    final controller = ref.read(dictationControllerProvider.notifier);
    final listening = ref.read(dictationControllerProvider).listening;
    if (listening) {
      await controller.stop();
    } else {
      // Adopt whatever is currently in the field (including manual edits) so
      // new speech appends after it.
      controller.setCommitted(_docController.text.trim());
      await controller.start();
    }
  }

  String _deriveTitle() {
    final typed = _titleController.text.trim();
    if (typed.isNotEmpty) return typed;
    final firstLine = _docController.text
        .trim()
        .split('\n')
        .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
    if (firstLine.isEmpty) return 'Untitled transcript';
    return firstLine.length > 48 ? '${firstLine.substring(0, 48)}…' : firstLine;
  }

  Future<void> _save() async {
    // Fold any in-progress dictation into the text before persisting.
    if (ref.read(dictationControllerProvider).listening) {
      await ref.read(dictationControllerProvider.notifier).stop();
    }
    final content = _docController.text.trim();
    if (content.isEmpty) {
      _snack('Nothing to save yet.');
      return;
    }
    setState(() => _saving = true);
    try {
      final repo = ref.read(transcriptRepositoryProvider);
      final title = _deriveTitle();
      if (_transcriptId == null) {
        final created = await repo.create(
            title: title, content: content, summary: _summary);
        _transcriptId = created.id;
      } else {
        await repo.update(_transcriptId!,
            title: title, content: content, summary: _summary);
      }
      ref.invalidate(transcriptsProvider);
      if (mounted) {
        _titleController.text = title;
        _snack('Saved.');
      }
    } catch (e) {
      _snack('Could not save: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Stops dictation and returns the document text, or null when there is
  /// nothing worth sending to the model.
  Future<String?> _textForAnalysis(String action) async {
    if (ref.read(dictationControllerProvider).listening) {
      await ref.read(dictationControllerProvider.notifier).stop();
    }
    final text = _docController.text.trim();
    if (text.isEmpty) {
      _snack('Nothing to $action yet.');
      return null;
    }
    return text;
  }

  Future<void> _summarize() async {
    final text = await _textForAnalysis('summarize');
    if (text == null) return;
    setState(() {
      _summarizing = true;
      _summary = null;
    });
    AiSession? session;
    try {
      session = await openAiSession(ref);
      final response = await session.client.createMessage(
        apiKey: session.apiKey,
        model: session.model,
        system: 'You summarize a transcript into clear, concise notes. Plain '
            'text only, no markdown headings. Start with a one-line gist, then '
            '3-6 bullet key points, then any action items. Be faithful to the '
            'transcript and do not invent details.',
        messages: [
          {
            'role': 'user',
            'content': 'Transcript:\n\n$text\n\nSummarize it.',
          },
        ],
        maxTokens: 1024,
      );
      final summary = response.text.trim();
      if (mounted) {
        setState(() =>
            _summary = summary.isEmpty ? '(The model returned nothing.)' : summary);
      }
    } catch (e) {
      _snack('Could not summarize: $e');
    } finally {
      session?.owned?.dispose();
      if (mounted) setState(() => _summarizing = false);
    }
  }

  /// Reads the transcript for things somebody committed to doing, then hands
  /// the candidates to the review sheet. Extraction is a suggestion, so it
  /// never writes anything on its own - see [showTaskReviewSheet].
  Future<void> _findTasks() async {
    final text = await _textForAnalysis('analyze');
    if (text == null) return;
    setState(() => _extracting = true);
    AiSession? session;
    try {
      session = await openAiSession(ref);
      final found = await extractTasksFromTranscript(
        client: session.client,
        model: session.model,
        apiKey: session.apiKey,
        transcript: text,
      );
      if (!mounted) return;
      if (found == null) {
        _snack('Could not read the model\'s reply. Try again, or switch '
            'provider in Settings.');
        return;
      }
      if (found.isEmpty) {
        _snack('No action items found in this transcript.');
        return;
      }
      final approved = await showTaskReviewSheet(context, found);
      if (approved == null || approved.isEmpty || !mounted) return;
      await _createTasks(approved);
    } catch (e) {
      _snack('Could not analyze: $e');
    } finally {
      session?.owned?.dispose();
      if (mounted) setState(() => _extracting = false);
    }
  }

  Future<void> _createTasks(List<ExtractedTask> approved) async {
    final repository = ref.read(taskRepositoryProvider);
    final calendarSync = ref.read(calendarSyncServiceProvider);
    final source = _deriveTitle();
    for (final candidate in approved) {
      final task = await repository.create(
        title: candidate.title,
        description: candidate.describeFrom(source),
        priority: candidate.priority,
        dueAt: candidate.dueAt,
        // The model proposed these, the user only approved them - same
        // provenance the agent's own create_task tool records.
        createdBy: 'agent',
      );
      // Mirror to the phone calendar when the user has that on.
      await calendarSync.syncTaskIfEnabled(task);
    }
    ref.invalidate(tasksProvider);
    ref.invalidate(todayDashboardProvider);
    _snack(approved.length == 1
        ? 'Task created.'
        : '${approved.length} tasks created.');
  }

  void _insertSummary() {
    final summary = _summary;
    if (summary == null || summary.isEmpty) return;
    final existing = _docController.text.trimRight();
    final combined = existing.isEmpty
        ? summary
        : '$existing\n\n--- Summary ---\n$summary';
    _docController.text = combined;
    _docController.selection =
        TextSelection.collapsed(offset: combined.length);
    ref.read(dictationControllerProvider.notifier).setCommitted(combined);
    _snack('Summary inserted into the document.');
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    // Mirror live dictation into the editable field, but only while listening
    // so manual edits made after stopping are never clobbered.
    ref.listen<DictationState>(dictationControllerProvider, (prev, next) {
      if (next.listening) {
        final text = next.fullText;
        if (_docController.text != text) {
          _docController.value = TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length),
          );
        }
      }
      if (next.error != null && prev?.error != next.error) {
        _snack(next.error!);
      }
    });

    final listening =
        ref.watch(dictationControllerProvider.select((s) => s.listening));

    return Scaffold(
      appBar: AppBar(
        title: Text(_transcriptId == null ? 'New transcript' : 'Transcript'),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else
            IconButton(
              tooltip: 'Save transcript',
              icon: const Icon(Icons.save_outlined),
              onPressed: _save,
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _toggleMic,
        backgroundColor: listening ? ExaColors.error : ExaColors.accent,
        foregroundColor: Colors.white,
        icon: Icon(listening ? Icons.stop : Icons.mic),
        label: Text(listening ? 'Stop' : 'Record'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _titleController,
                      textCapitalization: TextCapitalization.sentences,
                      style: Theme.of(context).textTheme.titleMedium,
                      decoration: const InputDecoration(
                        hintText: 'Title (optional)',
                        border: InputBorder.none,
                        isDense: true,
                      ),
                    ),
                    if (listening) _buildListeningChip(),
                    const SizedBox(height: 4),
                    Expanded(
                      child: TextField(
                        controller: _docController,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        keyboardType: TextInputType.multiline,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: InputDecoration(
                          hintText: 'Press Record and start speaking, or '
                              'type here…',
                          filled: true,
                          fillColor: ExaColors.surfaceHigh,
                          border: OutlineInputBorder(
                            borderRadius:
                                BorderRadius.circular(ExaRadii.field),
                            borderSide:
                                const BorderSide(color: ExaColors.outline),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius:
                                BorderRadius.circular(ExaRadii.field),
                            borderSide:
                                const BorderSide(color: ExaColors.outline),
                          ),
                          contentPadding: const EdgeInsets.all(14),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    _buildSummarySection(),
                    // Leave room so the Record FAB never covers the controls.
                    const SizedBox(height: 64),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildListeningChip() {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: ExaColors.error.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(ExaRadii.chip),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.fiber_manual_record,
                  size: 12, color: ExaColors.error),
              const SizedBox(width: 6),
              Text('Listening…',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: ExaColors.error, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSummarySection() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _summarize,
                icon: _summarizing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome, size: 18),
                label: Text(_summarizing ? 'Summarizing…' : 'Summarize'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _findTasks,
                icon: _extracting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.checklist, size: 18),
                label: Text(_extracting ? 'Analyzing…' : 'Find tasks'),
              ),
            ),
          ],
        ),
        if (_summary != null) ...[
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color: ExaColors.surfaceHigh,
              borderRadius: BorderRadius.circular(ExaRadii.card),
              border: Border.all(
                  color: ExaColors.accent.withValues(alpha: 0.35)),
            ),
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.auto_awesome,
                        size: 16, color: ExaColors.spark),
                    const SizedBox(width: 6),
                    Text('Summary',
                        style: theme.textTheme.labelLarge
                            ?.copyWith(color: ExaColors.spark)),
                  ],
                ),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 200),
                  child: SingleChildScrollView(
                    child: Text(_summary!,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(height: 1.35)),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: _summary!));
                        _snack('Summary copied.');
                      },
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('Copy'),
                    ),
                    const SizedBox(width: 4),
                    FilledButton.icon(
                      onPressed: _insertSummary,
                      icon: const Icon(Icons.playlist_add, size: 18),
                      label: const Text('Insert'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
