import 'package:exa_voice/exa_voice.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/voice/follow_ups.dart';
import '../../services/voice/speech_output.dart';
import '../../services/voice/wake_phrase.dart';
import '../../shared/providers.dart';
import '../../shared/theme/exa_theme.dart';

/// Exa as the phone's assistant, "Hey Exa", and what Exa tells you about
/// the things it adds by itself.
class VoiceSettingsScreen extends ConsumerStatefulWidget {
  const VoiceSettingsScreen({super.key});

  @override
  ConsumerState<VoiceSettingsScreen> createState() =>
      _VoiceSettingsScreenState();
}

class _VoiceSettingsScreenState extends ConsumerState<VoiceSettingsScreen>
    with WidgetsBindingObserver {
  static const _voice = ExaVoice();

  VoiceStatus _status = VoiceStatus.unavailable;
  bool _notify = true;
  bool _announce = false;
  bool _quietNow = false;
  ({DateTime at, String outcome, String title})? _lastAnnouncement;
  bool _busy = false;
  final _phraseController = TextEditingController();

  /// Slider position while dragging; saved when the drag ends.
  double? _dragSensitivity;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _phraseController.dispose();
    super.dispose();
  }

  // Coming back from a system settings page is when the answer changed.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  FollowUpAnnouncer get _announcer => FollowUpAnnouncer(
        settings: ref.read(settingsRepositoryProvider),
        isQuietNow: ref.read(notificationServiceProvider).isQuietNow,
      );

  Future<void> _refresh() async {
    final status = await _voice.status();
    final notify = await _announcer.notifyEnabled();
    final announce = await _announcer.announceEnabled();
    final last = await _announcer.lastAnnouncement();
    var quiet = false;
    try {
      quiet = await ref.read(notificationServiceProvider).isQuietNow();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _status = status;
      _notify = notify;
      _announce = announce;
      _lastAnnouncement = last;
      _quietNow = quiet;
    });
  }

  void _say(String text) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(text)));

  /// The slider reads "more sensitive" to the right; the spotter's
  /// threshold goes the other way; the default threshold, 0.15, sits at 2/3.
  static double _thresholdFor(double sensitivity) => 0.35 - 0.3 * sensitivity;
  static double _sensitivityFor(double threshold) =>
      ((0.35 - threshold) / 0.3).clamp(0.0, 1.0);

  Future<void> _savePhrase() async {
    final built = WakePhrase.forPhrase(_phraseController.text);
    if (built.value == null) {
      _say(built.error ?? 'That phrase cannot be used.');
      return;
    }
    final status = await _voice.configureWakeWord(
      phrase: built.value!.phrase,
      keywords: built.value!.keywords,
    );
    _phraseController.clear();
    if (!mounted) return;
    FocusScope.of(context).unfocus();
    setState(() => _status = status);
    _say('Exa now listens for "${built.value!.phrase}".');
  }

  /// "Hey Exa" again, with its tuned pronunciations and decoys.
  Future<void> _resetPhrase() async {
    final built = WakePhrase.forPhrase(WakePhrase.defaultPhrase).value!;
    final status = await _voice.configureWakeWord(
        phrase: built.phrase, keywords: built.keywords);
    if (mounted) setState(() => _status = status);
  }

  Future<void> _toggleWake(bool enabled) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final status = await _voice.setWakeWordEnabled(enabled);
      if (!mounted) return;
      setState(() => _status = status);
      if (enabled && !status.wakeRunning) {
        _say(status.wakeError ?? 'Could not start listening.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    // The service reports whether the engine took the key a moment later.
    await Future<void>.delayed(const Duration(seconds: 2));
    await _refresh();
  }

  Future<void> _setNotify(bool value) async {
    await ref
        .read(settingsRepositoryProvider)
        .setValue(FollowUpAnnouncer.notifyKey, '$value');
    await _refresh();
  }

  Future<void> _setAnnounce(bool value) async {
    await ref
        .read(settingsRepositoryProvider)
        .setValue(FollowUpAnnouncer.announceKey, '$value');
    await _refresh();
    if (value && !_status.canOpenFromBackground && mounted) {
      _say('Allow "Display over other apps" so Exa can open and speak by '
          'itself.');
      await _voice.openOverlaySettings();
    }
  }

  Future<void> _testAnnouncement() async {
    final delivered = await _announcer.test();
    await _refresh();
    if (!mounted) return;
    _say(switch (delivered) {
      'spoken' => 'Exa is opening to say it now.',
      'full_screen' => 'Sent as a full-screen notification.',
      'notified' => _announce
          ? 'Only a notification: Exa could not open by itself.'
          : 'Sent as a notification. Turn on "Say it out loud" to hear it.',
      _ => 'Could not post the test.',
    });
  }

  static String _outcomeText(String outcome) => switch (outcome) {
        'spoken' => 'said out loud',
        'full_screen' => 'sent full-screen',
        'notified' => 'notification only',
        'quiet_hours' => 'notification only (quiet hours)',
        'notifications_off' => 'not sent (notifications off)',
        _ => 'not sent',
      };

  static String _when(DateTime at) {
    final now = DateTime.now();
    final time = '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}';
    final sameDay =
        at.year == now.year && at.month == now.month && at.day == now.day;
    return sameDay ? 'today at $time' : '${at.day}/${at.month} at $time';
  }

  Widget _check(bool ok, String good, String bad) => Row(
        children: [
          Icon(ok ? Icons.check_circle : Icons.error_outline,
              size: 18, color: ok ? ExaColors.success : ExaColors.warning),
          const SizedBox(width: 8),
          Expanded(child: Text(ok ? good : bad)),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final s = _status;
    final theme = Theme.of(context);
    Widget heading(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
          child: Text(text,
              style: theme.textTheme.titleSmall
                  ?.copyWith(color: ExaColors.accent)),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('Voice & assistant')),
      body: ListView(
        children: [
          heading('Exa as your phone assistant'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _check(
                    s.isAssistant,
                    'Exa is your digital assistant app. Hold the side '
                        'button or swipe up from a bottom corner to talk.',
                    'Gemini or another app is the assistant. Choose Exa '
                        'under "Digital assistant app".'),
                const SizedBox(height: 8),
                FilledButton.tonal(
                  onPressed: _voice.openAssistantSettings,
                  child: const Text('Open default apps'),
                ),
                const SizedBox(height: 4),
                Text(
                  'On Samsung, also set Settings > Advanced features > Side '
                  'button > Press and hold to "Wake Digital assistant".',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: ExaColors.textSecondary),
                ),
              ],
            ),
          ),
          heading('Wake phrase'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Exa listens for its name on the phone itself - nothing is '
              'recorded or sent until it hears it. Works with the screen '
              'locked; a notification shows while it listens.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: ExaColors.textSecondary),
            ),
          ),
          SwitchListTile(
            title: Text('Listen for "${s.wakePhrase}"'),
            subtitle: Text(!s.wakeConfigured
                ? 'Not available in this build'
                : s.wakeListening
                    ? 'Listening, even with the screen locked'
                    : s.wakeRunning
                        ? (s.wakeError ?? 'Paused while Exa has the microphone')
                        : s.wakeError ?? 'Off'),
            value: s.wakeEnabled && s.wakeRunning,
            onChanged: s.wakeConfigured && !_busy ? _toggleWake : null,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _phraseController,
                    textCapitalization: TextCapitalization.words,
                    decoration: InputDecoration(
                      isDense: true,
                      labelText: 'Change the phrase',
                      hintText: s.wakePhrase,
                    ),
                    onSubmitted: (_) => _savePhrase(),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(onPressed: _savePhrase, child: const Text('Save')),
              ],
            ),
          ),
          if (s.wakePhrase != WakePhrase.defaultPhrase)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: _resetPhrase,
                  child: const Text('Back to "Hey Exa"'),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                const Text('Sensitivity'),
                Expanded(
                  child: Slider(
                    value: _dragSensitivity ??
                        _sensitivityFor(s.wakeThreshold),
                    divisions: 10,
                    onChanged: (v) => setState(() => _dragSensitivity = v),
                    onChangeEnd: (v) async {
                      final status = await _voice.configureWakeWord(
                          threshold: _thresholdFor(v));
                      if (!mounted) return;
                      setState(() {
                        _status = status;
                        _dragSensitivity = null;
                      });
                    },
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Higher hears you more easily but wakes by mistake more '
              'often. Two or three syllables work best ("Hey Exa"). You '
              'hear a short beep the moment Exa hears its name.\n'
              '${s.wakeDetections == 0 ? 'Not heard yet.' : 'Heard '
                  '${s.wakeDetections} time${s.wakeDetections == 1 ? '' : 's'}'
                  ', last ${_when(s.wakeLastDetection!)}.'}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: ExaColors.textSecondary),
            ),
          ),
          heading('When Exa adds things on its own'),
          SwitchListTile(
            title: const Text('Notify me'),
            subtitle: const Text(
                'A notification for each task, reminder or event a '
                'digest or job added, and for anything it could not add '
                'without asking you - with "Talk about it".'),
            value: _notify,
            onChanged: _setNotify,
          ),
          SwitchListTile(
            title: const Text('Say it out loud'),
            subtitle: Text(
                'Exa opens its voice session - over the lock screen too - '
                'tells you what it added and asks its follow-up questions. '
                'Never during your quiet hours.'
                '${_announce && _quietNow ? '\nQuiet hours are on now, so '
                    'Exa only notifies.' : ''}'
                '${_announce && !s.canOpenFromBackground ? '\nNeeds '
                    '"Display over other apps".' : ''}'),
            value: _announce,
            onChanged: _notify ? _setAnnounce : null,
          ),
          if (_announce && !s.canOpenFromBackground)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: OutlinedButton(
                onPressed: _voice.openOverlaySettings,
                child: const Text('Allow "Display over other apps"'),
              ),
            ),
          if (_lastAnnouncement case final last?)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                'Last: "${last.title}" - ${_outcomeText(last.outcome)}, '
                '${_when(last.at)}.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: ExaColors.textSecondary),
              ),
            ),
          ListTile(
            leading: const Icon(Icons.campaign_outlined),
            title: const Text('Test announcement'),
            subtitle: const Text(
                'Sends a sample, exactly as a real one goes out'),
            onTap: _testAnnouncement,
          ),
          heading('Try it'),
          ListTile(
            leading: const Icon(Icons.record_voice_over),
            title: const Text('Open the voice session'),
            subtitle: const Text('What the side button and "Hey Exa" open'),
            onTap: () => _voice.openSession(),
          ),
          ListTile(
            leading: const Icon(Icons.volume_up_outlined),
            title: const Text('Test Exa\'s voice'),
            subtitle: const Text(
                'Uses the phone\'s text-to-speech voice, chosen in Android '
                'settings'),
            onTap: () => ref.read(speechOutputProvider).speak(
                "Hi, I'm Exa. This is how I sound."),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
