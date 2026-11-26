import 'dart:async';

import 'package:exa_voice/exa_voice.dart';
import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../../agent/orchestrator/agent_orchestrator.dart';
import '../../agent/security/capability_policy.dart';
import '../../agent/services/tool_labels.dart';
import '../../data/repositories/chat_repository.dart';
import '../../services/voice/speech_output.dart';
import '../../services/voice/utterance_listener.dart';
import '../../shared/theme/exa_theme.dart';
import '../../shared/widgets/exa_orb.dart';

enum VoicePhase { starting, speaking, listening, thinking, ended }

/// One line of the session's transcript.
class VoiceLine {
  const VoiceLine(this.fromUser, this.text);
  final bool fromUser;
  final String text;
}

/// Phrases that end the session rather than go to Exa.
final voiceSessionEnd = RegExp(
  r"^(ok(ay)?[, ]+)?(stop|stop listening|goodbye|bye|bye exa|good ?night|"
  r"that'?s all|that is all|end (the )?conversation|thanks?,? that'?s all|"
  r"thank you,? that'?s all|never ?mind|no thanks?|nothing( else)?)[.!]?$",
  caseSensitive: false,
);

/// A spoken yes or no, for confirmations asked out loud.
bool? spokenYesNo(String text) {
  final t = text.toLowerCase().trim();
  if (RegExp(r"^(yes|yeah|yep|sure|ok(ay)?|go ahead|do it|please do|correct|"
          r"that'?s right)\b")
      .hasMatch(t)) {
    return true;
  }
  if (RegExp(r"^(no|nope|don'?t|do not|cancel|stop|never ?mind)\b")
      .hasMatch(t)) {
    return false;
  }
  return null;
}

/// Runs the conversation: speak, listen, think, speak again - until the
/// user says goodbye, goes quiet, or taps end.
class VoiceSessionController extends ChangeNotifier {
  VoiceSessionController({
    required this.orchestrator,
    required this.chat,
    this.voice = const ExaVoice(),
    SpeechOutput? speech,
  }) : speech = speech ?? SpeechOutput();

  final AgentOrchestrator orchestrator;
  final ChatRepository chat;
  final ExaVoice voice;
  final SpeechOutput speech;
  final SpeechToText _stt = SpeechToText();
  late final UtteranceListener _utterances =
      UtteranceListener(SpeechToTextPort(_stt));

  VoicePhase phase = VoicePhase.starting;
  bool locked = false;
  String partial = '';
  final List<VoiceLine> lines = [];
  String? problem;

  bool _sttReady = false;
  bool _ended = false;
  StreamSubscription<VoiceLaunch>? _launches;

  /// Empty listening windows in a row before the session ends by itself.
  static const _maxSilences = 2;

  Future<void> start() async {
    _launches = voice.launches.listen((launch) => _begin(launch));
    final launch = await voice.consumeLaunch() ??
        const VoiceLaunch(mode: VoiceLaunch.listen);
    await _begin(launch);
  }

  bool _running = false;

  Future<void> _begin(VoiceLaunch launch) async {
    // A second launch while talking (another follow-up, the side button
    // again) does not start a second conversation over the first; its
    // notification stays for later.
    if (_running || _ended) return;
    _running = true;
    locked = await voice.isLocked();
    _sttReady = _sttReady ||
        await _stt.initialize(onError: (_) {}, onStatus: (_) {});
    if (!_sttReady) {
      problem = 'Exa cannot use the microphone. Allow it in the app '
          'settings, then try again.';
      _set(VoicePhase.ended);
      return;
    }
    final opening = launch.speak?.trim() ?? '';
    if (launch.isFollowUp && opening.isNotEmpty) {
      // In the chat history too, so the next turn - here or later in the
      // app - knows what the user is answering.
      try {
        await chat.append('assistant', opening,
            meta: {'source': 'voice_follow_up'});
      } catch (_) {}
      await _say(opening);
    } else if (!launch.isFollowUp) {
      await _say(locked ? 'Yes?' : 'Hi, what can I do?');
    }
    await _conversationLoop();
  }

  Future<void> _conversationLoop() async {
    var silences = 0;
    while (!_ended) {
      final heard = await _listen();
      if (_ended) return;
      if (heard == null || heard.trim().isEmpty) {
        silences++;
        if (silences >= _maxSilences) {
          await end();
          return;
        }
        continue;
      }
      silences = 0;
      lines.add(VoiceLine(true, heard));
      notifyListeners();
      if (voiceSessionEnd.hasMatch(heard.trim())) {
        await _say('Okay. Talk soon.');
        await end();
        return;
      }
      final reply = await _think(heard);
      if (_ended) return;
      await _say(reply);
    }
  }

  /// Silence longer than this while thinking is answered with a word, so a
  /// slow model does not look like Exa not having heard.
  static const holdOn = Duration(seconds: 4);

  /// A turn that takes longer than this is given up on out loud; its answer
  /// still lands in the chat when the model finishes. On a local server
  /// that is busy with a background digest, a turn can wait minutes.
  static const giveUp = Duration(minutes: 2);

  Future<String> _think(String text) async {
    _set(VoicePhase.thinking);
    final run = orchestrator.run(
      text,
      onConfirm: _confirmAloud,
      // On the lock screen anyone could be holding the phone: reads and
      // local changes only, everything else waits for an unlock.
      policy: locked ? CapabilityPolicy.lockScreen : null,
      userMeta: const {'source': 'voice'},
    );
    final holdOnTimer = Timer(holdOn, () {
      if (phase == VoicePhase.thinking && !_ended) {
        speech.speak('One moment.');
      }
    });
    try {
      final result = await run.timeout(giveUp);
      final reply = result.assistantText.trim();
      return reply.isEmpty ? 'Done.' : reply;
    } on TimeoutException {
      return 'Sorry, that is taking too long - the AI server may be busy '
          'with something else. I will put the answer in the chat when it '
          'is ready.';
    } catch (e) {
      return 'Sorry, that did not work. $e';
    } finally {
      holdOnTimer.cancel();
    }
  }

  /// Asks for approval out loud, and takes a spoken yes or no.
  Future<bool> _confirmAloud(String tool, Map<String, Object?> input) async {
    final action = ToolLabels.describe(tool);
    for (var attempt = 0; attempt < 2; attempt++) {
      await _say(attempt == 0
          ? 'Should I $action? Say yes or no.'
          : 'Sorry, yes or no?');
      final heard = await _listen();
      final answer = heard == null ? null : spokenYesNo(heard);
      if (heard != null && heard.isNotEmpty) {
        lines.add(VoiceLine(true, heard));
      }
      if (answer != null) {
        _set(VoicePhase.thinking);
        return answer;
      }
    }
    _set(VoicePhase.thinking);
    return false;
  }

  Future<void> _say(String text) async {
    if (_ended || text.trim().isEmpty) return;
    lines.add(VoiceLine(false, text));
    _set(VoicePhase.speaking);
    await speech.speak(text);
  }

  /// One utterance, or null when nothing was said. The turn ends after a
  /// real silence, not at the recogniser's first pause - see
  /// [UtteranceListener].
  Future<String?> _listen() async {
    if (_ended) return null;
    partial = '';
    _set(VoicePhase.listening);
    final heard = await _utterances.listen(onWords: (text) {
      partial = text;
      notifyListeners();
    });
    partial = '';
    return heard;
  }

  /// Tap on the orb: interrupt Exa, or stop waiting and listen now.
  Future<void> interrupt() async {
    if (phase == VoicePhase.speaking) await speech.stop();
  }

  Future<void> end() async {
    if (_ended) return;
    _ended = true;
    await speech.stop();
    _utterances.cancel();
    if (_stt.isListening) await _stt.cancel();
    _set(VoicePhase.ended);
    await _launches?.cancel();
    await voice.finishSession();
  }

  void _set(VoicePhase next) {
    phase = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _ended = true;
    speech.stop();
    _stt.cancel();
    _launches?.cancel();
    super.dispose();
  }
}

/// The voice session's whole UI: the orb, what was said, and a way out.
class VoiceSessionScreen extends StatefulWidget {
  const VoiceSessionScreen({super.key, required this.controller});

  final VoiceSessionController controller;

  @override
  State<VoiceSessionScreen> createState() => _VoiceSessionScreenState();
}

class _VoiceSessionScreenState extends State<VoiceSessionScreen> {
  VoiceSessionController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_changed);
    c.start();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    c.dispose();
    super.dispose();
  }

  String get _status => switch (c.phase) {
        VoicePhase.starting => 'Starting...',
        VoicePhase.speaking => 'Exa is speaking - tap to interrupt',
        VoicePhase.listening =>
          c.partial.isEmpty ? 'Listening...' : c.partial,
        VoicePhase.thinking => 'Thinking...',
        VoicePhase.ended => c.problem ?? 'Goodbye',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recent = c.lines.length > 6
        ? c.lines.sublist(c.lines.length - 6)
        : c.lines;
    return Scaffold(
      backgroundColor: ExaColors.surface,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            children: [
              Row(
                children: [
                  Icon(c.locked ? Icons.lock_outline : Icons.lock_open,
                      size: 16, color: ExaColors.textSecondary),
                  const SizedBox(width: 6),
                  Text(
                    c.locked
                        ? 'Locked - Exa can read and add, not send or delete'
                        : 'Exa voice',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: ExaColors.textSecondary),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'End',
                    icon: const Icon(Icons.close),
                    onPressed: c.end,
                  ),
                ],
              ),
              Expanded(
                child: ListView(
                  reverse: true,
                  children: [
                    for (final line in recent.reversed)
                      Align(
                        alignment: line.fromUser
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          constraints: BoxConstraints(
                              maxWidth:
                                  MediaQuery.of(context).size.width * 0.8),
                          decoration: BoxDecoration(
                            color: line.fromUser
                                ? ExaColors.accentContainer
                                : ExaColors.surfaceHigh,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Text(
                            line.text,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: line.fromUser
                                  ? ExaColors.onAccentContainer
                                  : ExaColors.textPrimary,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              GestureDetector(
                onTap: c.interrupt,
                child: ExaOrb(
                  size: 96,
                  thinking: c.phase == VoicePhase.thinking ||
                      c.phase == VoicePhase.speaking,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                _status,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyLarge
                    ?.copyWith(color: ExaColors.textSecondary),
              ),
              const SizedBox(height: 8),
              Text(
                "Say \"goodbye\" when you're done.",
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: ExaColors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
