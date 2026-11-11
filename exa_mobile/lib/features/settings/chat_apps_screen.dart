import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../services/messaging/messaging_bridge.dart';
import '../../shared/providers.dart';

/// Everything about chat capture in one place, in the order the user has to
/// do it: grant, choose apps, switch on.
class _CaptureState {
  const _CaptureState({
    required this.hasAccess,
    required this.connected,
    required this.enabled,
    required this.apps,
    required this.pending,
    required this.dropped,
    this.probe = const [],
  });

  final bool hasAccess;
  final bool connected;
  final bool enabled;
  final List<SupportedChatApp> apps;
  final int pending;
  final int dropped;

  /// Media-probe attempts the listener has recorded so far; empty until a
  /// real media notification has been seen.
  final List<MediaProbeRecord> probe;

  bool get anyAllowed => apps.any((a) => a.allowed);
}

final _captureStateProvider =
    FutureProvider.autoDispose<_CaptureState>((ref) async {
  final bridge = ref.watch(messagingBridgeProvider);
  return _CaptureState(
    hasAccess: await bridge.hasNotificationAccess(),
    connected: await bridge.isListenerConnected(),
    enabled: await bridge.isCaptureEnabled(),
    apps: await bridge.supportedApps(),
    pending: await bridge.spoolPendingCount(),
    dropped: await bridge.droppedCount(),
    probe: await bridge.mediaProbeReport(),
  );
});

/// Settings > Chat apps.
///
/// The screen is as much an explanation as a control panel, because what
/// this feature can and cannot do is genuinely surprising: it reads
/// notifications, so it sees nothing from before it was switched on, nothing
/// from a chat that is open on screen, and only as much of a long message as
/// the shade showed. A user who is not told that will read a digest as if it
/// were complete.
class ChatAppsScreen extends ConsumerWidget {
  const ChatAppsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stateAsync = ref.watch(_captureStateProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Chat apps')),
      body: stateAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Error: $error')),
        data: (state) => ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            _IntroCard(state: state),
            const Divider(height: 1),
            _AccessTile(state: state),
            _EnableTile(state: state),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text('Apps Exa may read',
                  style: Theme.of(context).textTheme.titleSmall),
            ),
            if (state.apps.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text('None of the supported chat apps are installed. '
                    'Exa supports WhatsApp, WhatsApp Business, Signal, '
                    'Telegram and Google Messages.'),
              ),
            for (final app in state.apps) _AppToggle(app: app),
            const Divider(height: 1),
            _ImportTile(),
            _InboxTile(state: state),
            if (state.dropped > 0) _DroppedTile(dropped: state.dropped),
            MediaProbeTile(records: state.probe),
            const _LimitsCard(),
          ],
        ),
      ),
    );
  }
}

class _IntroCard extends StatelessWidget {
  const _IntroCard({required this.state});

  final _CaptureState state;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        'WhatsApp has no API for personal accounts, so Exa reads chat '
        'messages the only way Android allows: from their notifications. '
        'Everything stays on this device.',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    );
  }
}

class _AccessTile extends ConsumerWidget {
  const _AccessTile({required this.state});

  final _CaptureState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final granted = state.hasAccess;
    return ListTile(
      leading: Icon(
        granted ? Icons.verified_user : Icons.gpp_maybe_outlined,
        color: granted ? Colors.green : Theme.of(context).colorScheme.error,
      ),
      title: const Text('Notification access'),
      subtitle: Text(granted
          ? state.connected
              ? 'Granted and running'
              : 'Granted — waiting for Android to connect the service'
          : 'Required. Android does not let apps ask for this, so it has to '
              'be switched on by hand.'),
      trailing: const Icon(Icons.open_in_new, size: 18),
      onTap: () async {
        final bridge = ref.read(messagingBridgeProvider);
        await bridge.openNotificationAccessSettings();
        // The user comes back from a system page; nothing tells us when, so
        // the state is re-read on the next frame they land on.
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await bridge.rebindListener();
        ref.invalidate(_captureStateProvider);
      },
    );
  }
}

class _EnableTile extends ConsumerWidget {
  const _EnableTile({required this.state});

  final _CaptureState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SwitchListTile(
      secondary: const Icon(Icons.forum_outlined),
      title: const Text('Capture chat messages'),
      subtitle: Text(state.hasAccess
          ? state.anyAllowed
              ? 'Exa keeps messages from the apps ticked below.'
              : 'Tick at least one app below — nothing is captured until you do.'
          : 'Grant notification access first.'),
      value: state.enabled && state.hasAccess,
      onChanged: state.hasAccess
          ? (value) async {
              final bridge = ref.read(messagingBridgeProvider);
              await bridge.setCaptureEnabled(value);
              // Mirrored into the database so a background job can word its
              // report correctly without reaching the platform channel.
              await ref
                  .read(messageIngestServiceProvider)
                  .recordCaptureEnabled(value);
              ref.invalidate(_captureStateProvider);
            }
          : null,
    );
  }
}

class _AppToggle extends ConsumerWidget {
  const _AppToggle({required this.app});

  final SupportedChatApp app;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return CheckboxListTile(
      title: Text(app.label),
      subtitle: Text(app.packageName),
      value: app.allowed,
      onChanged: (value) async {
        final bridge = ref.read(messagingBridgeProvider);
        final current = (await bridge.allowedPackages()).toSet();
        if (value == true) {
          current.add(app.packageName);
        } else {
          current.remove(app.packageName);
        }
        await bridge.setAllowedPackages(current.toList());
        ref.invalidate(_captureStateProvider);
      },
    );
  }
}

class _ImportTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: const Icon(Icons.history),
      title: const Text('Import a chat export'),
      subtitle: const Text(
          'The only way to give Exa history. In WhatsApp: open a chat, '
          'More > Export chat > Without media.'),
      onTap: () => _import(context, ref),
    );
  }

  static Future<void> _import(BuildContext context, WidgetRef ref) async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['txt', 'zip'],
      withData: true,
    );
    final file = picked?.files.singleOrNull;
    if (file == null) return;

    // Only .txt is read here: a .zip has to come through the share sheet,
    // where the native side can unpack it. Saying so beats a silent failure.
    if (file.extension?.toLowerCase() == 'zip') {
      if (context.mounted) {
        _say(context,
            'Share the .zip to Exa from your file manager instead — Exa '
            'unpacks it there. Or export the chat without media to get a '
            '.txt you can pick here.');
      }
      return;
    }

    final bytes = file.bytes;
    if (bytes == null) {
      if (context.mounted) _say(context, 'That file could not be read.');
      return;
    }

    final result = await ref.read(messageIngestServiceProvider).importExport(
          String.fromCharCodes(bytes),
          fileName: file.name,
        );
    ref.invalidate(_captureStateProvider);
    ref.invalidate(conversationsProvider);
    if (context.mounted) _say(context, result.result.summary);
  }

  static void _say(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

class _InboxTile extends StatelessWidget {
  const _InboxTile({required this.state});

  final _CaptureState state;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.inbox_outlined),
      title: const Text('Captured messages'),
      subtitle: Text(state.pending > 0
          ? '${state.pending} waiting to be taken in'
          : 'Chats and messages Exa has'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => context.go('/settings/messages'),
    );
  }
}

class _DroppedTile extends ConsumerWidget {
  const _DroppedTile({required this.dropped});

  final int dropped;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: Icon(Icons.warning_amber_outlined,
          color: Theme.of(context).colorScheme.error),
      title: Text('$dropped captured message'
          '${dropped == 1 ? '' : 's'} were discarded'),
      subtitle: const Text(
          'Messages piled up faster than Exa took them in and the oldest '
          'were dropped. Adding a "Take in chat messages" job on a short '
          'interval prevents it. Tap to acknowledge.'),
      onTap: () async {
        await ref.read(messagingBridgeProvider).clearDroppedCount();
        ref.invalidate(_captureStateProvider);
      },
    );
  }
}

/// Media-probe matrix: what the notification listener could and could not
/// open inside each allowed chat app's media notifications.
///
/// This is the developer-facing record of the C3 spike, surfaced in Settings
/// so a support conversation can read the same matrix the adb log would show
/// - except that logcat scrolls away and this does not. It is deliberately
/// read-only and shows no URIs: a content URI can carry a signed or expiring
/// token, so on screen, exactly as in the log and the persisted report, the
/// only facts are the mime type, the bytes read or why not, and which slot
/// of the notification the media came from.
///
/// Takes the records as a constructor argument rather than watching a
/// provider so the tile can be widget-tested from a fixture.
class MediaProbeTile extends StatelessWidget {
  const MediaProbeTile({super.key, required this.records});

  /// One line each, newest last; an empty list renders nothing, because a
  /// card that announces "media checks" before a single media notification
  /// has been seen is noise on an otherwise clean screen.
  final List<MediaProbeRecord> records;

  @override
  Widget build(BuildContext context) {
    if (records.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Media in chat notifications, checked on ${records.first.deviceLabel}",
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          for (final record in records) Text(_lineFor(record), style: style),
          const SizedBox(height: 8),
          Text(
            'Exa is checking whether each app lets it open message media. '
            'Nothing here means media has been attached to a message yet, '
            'and no media links are ever stored or shown.',
            style: style,
          ),
        ],
      ),
    );
  }

  /// "app · mime · origin · outcome". The failure words are the user-facing
  /// reading of the probe's failure classes; bytes stand in for the outcome
  /// when the read worked.
  static String _lineFor(MediaProbeRecord record) {
    final app = record.packageName.split('.').last;
    final mime = (record.mimeType ?? '').trim().isEmpty
        ? 'no mime'
        : record.mimeType!.trim();
    final origin = record.origin == 'notification_picture'
        ? 'notification picture (unverified)'
        : 'message attachment';
    final outcome = switch (record.failure) {
      'ok' => '${record.bytesRead} bytes read',
      'security' => 'blocked',
      'not_found' => 'not found',
      'empty_stream' => 'empty',
      'null_uri' => 'no uri',
      'unsupported_scheme' => 'not a media link',
      _ => record.failure.isEmpty ? 'unknown' : record.failure,
    };
    return '• $app · $mime · $origin · $outcome';
  }
}

class _LimitsCard extends StatelessWidget {
  const _LimitsCard();
  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('What Exa will and will not see',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Text(
            '• Nothing from before you switched this on. Import a chat '
            'export for history.',
            style: style,
          ),
          Text(
            '• Nothing from a chat that is open on your screen — Android '
            'posts no notification for it.',
            style: style,
          ),
          Text(
            '• Long messages may be cut off. Photos are saved up to 3 MiB '
            'and voice notes up to 8 MiB, and captured media stays on this '
            'device - it is never uploaded to the internet. Images are '
            'only ever shown to an AI provider that can see them; when '
            'yours cannot, Exa says so instead of guessing at the picture. '
            'A voice note is transcribed into text by the local AI server '
            'you set in Settings > AI provider, and its audio goes only '
            'to that server and nowhere else; a voice note with no '
            'transcript yet shows only its size and format. Documents '
            'still appear only as a placeholder. An app that puts no '
            'media into its notification gives Exa nothing to save - the '
            'matrix above shows what each app actually hands over.',
            style: style,
          ),
          Text(
            '• Replies go out through the chat app itself, so they only '
            'work while the message is still unread.',
            style: style,
          ),
          Text(
            '• Exa never replies on its own. A reply always needs you to '
            'approve it.',
            style: style,
          ),
          const SizedBox(height: 12),
          Text('Notification access covers every app on the phone. Exa reads '
              'only the apps ticked above and discards the rest without '
              'storing them.', style: style),
        ],
      ),
    );
  }
}
